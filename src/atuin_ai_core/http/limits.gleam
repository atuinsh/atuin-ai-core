pub type ChargeTarget {
  User(String)
  Org(String)
}

pub type LimitDetails {
  LimitDetails(
    limit_type: String,
    limit: Int,
    used: Int,
    retry_after_seconds: Int,
  )
}

pub type LimitCheckError {
  Disabled
  LimitExceeded(LimitDetails)
  Unknown(String)
}

/// Period credit totals for a charge target, as stored — the in-flight
/// turn isn't recorded yet, so callers add its credits themselves. Limits
/// use the UsageLimit sentinels: -1 unlimited, 0 disabled. The Elixir FFI
/// builds the tuple, so field order is the FFI contract.
pub type CreditsSnapshot {
  CreditsSnapshot(
    period: String,
    resets_at: String,
    requests_used: Int,
    requests_limit: Int,
    input_used: Int,
    input_limit: Int,
    output_used: Int,
    output_limit: Int,
  )
}
