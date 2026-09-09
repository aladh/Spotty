use crate::*;

static DEVICE_ID: once_cell::sync::OnceCell<String> = once_cell::sync::OnceCell::new();

fn valid_device_id(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Installs the non-secret opaque installation identity before any session starts. The input
/// is copied during the call and must be a valid NUL-terminated string of 40 ASCII hex digits.
/// Repeating the same identity succeeds; changing it during the process lifetime fails.
/// Returns 0 on success and -1 for missing, invalid, or conflicting identity.
#[no_mangle]
pub extern "C" fn spotty_playback_set_device_id(device_id: *const c_char) -> i32 {
    ffi_command("spotty_playback_set_device_id", || {
        let Some(value) = (unsafe { c_string_arg(device_id) }) else {
            return -1;
        };
        if !valid_device_id(&value) {
            return -1;
        }
        let value = value.to_ascii_lowercase();
        let installed = DEVICE_ID.get_or_init(|| value.clone());
        if installed == &value {
            0
        } else {
            -1
        }
    })
}

pub(crate) fn configured_device_id() -> Option<String> {
    DEVICE_ID.get().cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installation_identity_is_validated_and_immutable() {
        assert!(!valid_device_id("spotty_123"));
        assert!(!valid_device_id(&"é".repeat(20)));
        assert!(!valid_device_id(&"g".repeat(40)));
        let id = CString::new("0123456789abcdef0123456789abcdef01234567").unwrap();
        assert_eq!(spotty_playback_set_device_id(id.as_ptr()), 0);
        assert_eq!(spotty_playback_set_device_id(id.as_ptr()), 0);
        let other = CString::new("f".repeat(40)).unwrap();
        assert_eq!(spotty_playback_set_device_id(other.as_ptr()), -1);
        assert_eq!(configured_device_id().as_deref(), id.to_str().ok());
    }
}
