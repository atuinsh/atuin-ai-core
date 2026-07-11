@external(erlang, "uuid_ffi", "generate")
pub fn uuidv7() -> String

@external(erlang, "uuid_ffi", "valid")
pub fn valid(uuid: String) -> Bool
