use super::CommandError;

static DEVICE_ID: once_cell::sync::OnceCell<String> = once_cell::sync::OnceCell::new();

fn valid_device_id(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(crate) fn set_device_id(value: &str) -> Result<(), CommandError> {
    if !valid_device_id(value) {
        return Err(CommandError::Failed);
    }
    let value = value.to_ascii_lowercase();
    let installed = DEVICE_ID.get_or_init(|| value.clone());
    if installed == &value {
        Ok(())
    } else {
        Err(CommandError::Failed)
    }
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
        let id = "0123456789abcdef0123456789abcdef01234567";
        assert_eq!(set_device_id(id), Ok(()));
        assert_eq!(set_device_id(id), Ok(()));
        assert_eq!(set_device_id(&"f".repeat(40)), Err(CommandError::Failed));
        assert_eq!(configured_device_id().as_deref(), Some(id));
    }
}
