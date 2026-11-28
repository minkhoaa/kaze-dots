#![deny(clippy::unwrap_used)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::path::Path;
use std::ptr;
use zeroize::Zeroizing;

#[repr(C)]
struct PamHandle {
    _private: [u8; 0],
}

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

type PamConvFn = unsafe extern "C" fn(
    num_msg: c_int,
    msg: *mut *const PamMessage,
    resp: *mut *mut PamResponse,
    appdata_ptr: *mut c_void,
) -> c_int;

#[repr(C)]
struct PamConv {
    conv: Option<PamConvFn>,
    appdata_ptr: *mut c_void,
}

const PAM_SUCCESS: c_int = 0;
const PAM_OPEN_ERR: c_int = 1;
const PAM_SERVICE_ERR: c_int = 3;
const PAM_BUF_ERR: c_int = 5;
const PAM_CONV_ERR: c_int = 19;

const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const PAM_ERROR_MSG: c_int = 3;
const PAM_TEXT_INFO: c_int = 4;

#[link(name = "pam")]
unsafe extern "C" {
    fn pam_start(
        service_name: *const c_char,
        user: *const c_char,
        pam_conversation: *const PamConv,
        pamh: *mut *mut PamHandle,
    ) -> c_int;
    fn pam_end(pamh: *mut PamHandle, pam_status: c_int) -> c_int;
    fn pam_authenticate(pamh: *mut PamHandle, flags: c_uint) -> c_int;
    fn pam_acct_mgmt(pamh: *mut PamHandle, flags: c_uint) -> c_int;
    fn pam_strerror(pamh: *mut PamHandle, errnum: c_int) -> *const c_char;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PamOutcome {
    Authenticated,
    Failed(String),
}

pub fn default_pam_service_exists(service: &str) -> bool {
    if service.trim().is_empty() || service.contains('/') {
        return false;
    }
    Path::new("/etc/pam.d").join(service).exists()
        || Path::new("/usr/lib/pam.d").join(service).exists()
}

pub fn resolve_pam_service(preferred: &str, service_exists: impl Fn(&str) -> bool) -> String {
    let trimmed = preferred.trim();
    if trimmed.is_empty() {
        return "login".to_string();
    }
    if service_exists(trimmed) || !service_exists("login") {
        trimmed.to_string()
    } else {
        "login".to_string()
    }
}

pub fn current_username() -> String {
    if let Ok(u) = std::env::var("USER") {
        if !u.trim().is_empty() {
            return u;
        }
    }
    // SAFETY: `geteuid` and `getpwuid` are standard libc calls; pointer is checked non-null.
    unsafe {
        let uid = libc::geteuid();
        let pw = libc::getpwuid(uid);
        if !pw.is_null() && !(*pw).pw_name.is_null() {
            if let Ok(name) = CStr::from_ptr((*pw).pw_name).to_str() {
                if !name.trim().is_empty() {
                    return name.to_string();
                }
            }
        }
    }
    "user".to_string()
}

struct ConvState<'a> {
    password: &'a Zeroizing<String>,
    error_message: Option<String>,
}

unsafe extern "C" fn pam_conversation(
    num_msg: c_int,
    msg: *mut *const PamMessage,
    resp: *mut *mut PamResponse,
    appdata_ptr: *mut c_void,
) -> c_int {
    if num_msg <= 0 || msg.is_null() || resp.is_null() || appdata_ptr.is_null() {
        return PAM_CONV_ERR;
    }

    // SAFETY: caller ensures `appdata_ptr` points to a live `ConvState` for the duration of PAM.
    let state = unsafe { &mut *(appdata_ptr as *mut ConvState<'_>) };
    let count = num_msg as usize;

    // SAFETY: libpam expects `resp` to be allocated with `calloc` and frees both `resp` and `resp[i].resp`.
    let responses = unsafe { libc::calloc(count, std::mem::size_of::<PamResponse>()) }
        as *mut PamResponse;
    if responses.is_null() {
        return PAM_BUF_ERR;
    }

    for i in 0..count {
        // SAFETY: `msg` holds `num_msg` message pointers supplied by libpam.
        let m_ptr = unsafe { *msg.add(i) };
        if m_ptr.is_null() {
            // SAFETY: free any strings allocated so far before returning error.
            unsafe {
                free_responses(responses, i);
            }
            return PAM_CONV_ERR;
        }
        // SAFETY: `m_ptr` is verified non-null above.
        let m = unsafe { &*m_ptr };
        match m.msg_style {
            PAM_PROMPT_ECHO_OFF | PAM_PROMPT_ECHO_ON => {
                let mut pw_bytes = Zeroizing::new(state.password.as_bytes().to_vec());
                if pw_bytes.contains(&0) {
                    // SAFETY: cleanup previously allocated entries.
                    unsafe {
                        free_responses(responses, i);
                    }
                    return PAM_CONV_ERR;
                }
                pw_bytes.push(0);
                // SAFETY: `strdup` allocates a `free()`-able buffer copied from NUL-terminated `pw_bytes`.
                let dup = unsafe { libc::strdup(pw_bytes.as_ptr() as *const c_char) };
                if dup.is_null() {
                    // SAFETY: cleanup previously allocated entries.
                    unsafe {
                        free_responses(responses, i);
                    }
                    return PAM_BUF_ERR;
                }
                // SAFETY: `responses` has `count` elements.
                unsafe {
                    (*responses.add(i)).resp = dup;
                    (*responses.add(i)).resp_retcode = 0;
                }
            }
            PAM_ERROR_MSG => {
                if !m.msg.is_null() {
                    // SAFETY: PAM guarantees NUL-terminated message strings.
                    if let Ok(text) = unsafe { CStr::from_ptr(m.msg) }.to_str() {
                        let trimmed = text.trim();
                        if !trimmed.is_empty() {
                            state.error_message = Some(trimmed.to_string());
                        }
                    }
                }
            }
            PAM_TEXT_INFO => {}
            _ => {}
        }
    }

    // SAFETY: `resp` is non-null output pointer from libpam.
    unsafe {
        *resp = responses;
    }
    PAM_SUCCESS
}

unsafe fn free_responses(responses: *mut PamResponse, allocated: usize) {
    for j in 0..allocated {
        // SAFETY: freeing partial buffer entries on conversation abort.
        unsafe {
            let ptr = (*responses.add(j)).resp;
            if !ptr.is_null() {
                let len = libc::strlen(ptr);
                libc::explicit_bzero(ptr as *mut c_void, len);
                libc::free(ptr as *mut c_void);
            }
        }
    }
    // SAFETY: `responses` was allocated via `libc::calloc`.
    unsafe {
        libc::free(responses as *mut c_void);
    }
}

pub fn authenticate(
    preferred_service: &str,
    username: &str,
    mut password: Zeroizing<String>,
) -> PamOutcome {
    let service = resolve_pam_service(preferred_service, default_pam_service_exists);
    let outcome = authenticate_with_service(&service, username, &password);
    let final_outcome = match outcome {
        Err(rc) if (rc == PAM_SERVICE_ERR || rc == PAM_OPEN_ERR) && service != "login" => {
            authenticate_with_service("login", username, &password)
                .unwrap_or_else(|e| PamOutcome::Failed(format!("Authentication error ({e})")))
        }
        Err(rc) => PamOutcome::Failed(format!("Authentication error ({rc})")),
        Ok(res) => res,
    };
    *password = String::new();
    drop(password);
    final_outcome
}

fn authenticate_with_service(
    service: &str,
    username: &str,
    password: &Zeroizing<String>,
) -> Result<PamOutcome, c_int> {
    let c_service = CString::new(service).map_err(|_| PAM_SERVICE_ERR)?;
    let c_user = CString::new(username).map_err(|_| PAM_CONV_ERR)?;

    let mut conv_state = ConvState {
        password,
        error_message: None,
    };
    let conv = PamConv {
        conv: Some(pam_conversation),
        appdata_ptr: (&mut conv_state as *mut ConvState<'_>).cast::<c_void>(),
    };

    let mut pamh: *mut PamHandle = ptr::null_mut();
    // SAFETY: valid C strings and `PamConv` pointer passed for start.
    let start_rc = unsafe { pam_start(c_service.as_ptr(), c_user.as_ptr(), &conv, &mut pamh) };
    if start_rc != PAM_SUCCESS || pamh.is_null() {
        if !pamh.is_null() {
            // SAFETY: clean up failed handle if initialized.
            unsafe {
                pam_end(pamh, start_rc);
            }
        }
        return Err(start_rc);
    }

    // SAFETY: `pamh` is valid until `pam_end`.
    let auth_rc = unsafe { pam_authenticate(pamh, 0) };
    let final_rc = if auth_rc == PAM_SUCCESS {
        // SAFETY: verify account validity when auth succeeds.
        unsafe { pam_acct_mgmt(pamh, 0) }
    } else {
        auth_rc
    };

    let err_detail = if final_rc != PAM_SUCCESS {
        conv_state.error_message.clone().or_else(|| {
            // SAFETY: `pam_strerror` returns static/handle-scoped message string.
            let p = unsafe { pam_strerror(pamh, final_rc) };
            if p.is_null() {
                None
            } else {
                // SAFETY: non-null string returned by libpam.
                unsafe { CStr::from_ptr(p) }
                    .to_str()
                    .ok()
                    .map(|s| s.to_string())
            }
        })
    } else {
        None
    };

    // SAFETY: always end PAM transaction.
    unsafe {
        pam_end(pamh, final_rc);
    }

    if final_rc == PAM_SUCCESS {
        Ok(PamOutcome::Authenticated)
    } else {
        Ok(PamOutcome::Failed(
            err_detail.unwrap_or_else(|| "Incorrect password".to_string()),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_service_uses_preferred_when_present_else_login() {
        let s1 = resolve_pam_service("kaze-shell", |name| name == "kaze-shell" || name == "login");
        assert_eq!(s1, "kaze-shell");

        let s2 = resolve_pam_service("kaze-shell", |name| name == "login");
        assert_eq!(s2, "login");

        let s3 = resolve_pam_service("", |name| name == "login");
        assert_eq!(s3, "login");
    }
}
