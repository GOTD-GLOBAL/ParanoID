use paranoid_key_protocol::identity_v3::{parse_generation, IdentityChallengeV3, ProofRole};

#[test]
fn transcript_matches_independent_public_vectors() {
    let vectors: serde_json::Value = serde_json::from_str(include_str!(
        "../../docs/protocol/identity-login-v3-vectors.json"
    ))
    .unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let mut data = case["challenge"].clone();
        data["expires"] = data["expires"]
            .as_str()
            .unwrap()
            .parse::<i64>()
            .unwrap()
            .into();
        let challenge: IdentityChallengeV3 = serde_json::from_value(data).unwrap();
        let role = if case["role"] == "owner" {
            ProofRole::Owner
        } else {
            ProofRole::Device
        };
        let bytes = challenge.transcript(role).unwrap();
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, case["transcript_hex"].as_str().unwrap());
        assert_eq!(
            paranoid_key_protocol::digest(&bytes),
            case["sha256"].as_str().unwrap()
        );
        paranoid_key_protocol::verify(
            case["public_key"].as_str().unwrap(),
            &bytes,
            case["signature"].as_str().unwrap(),
        )
        .unwrap();
    }
}

#[test]
fn generation_is_canonical_bounded_decimal() {
    assert_eq!(parse_generation("0"), Ok(0));
    assert_eq!(parse_generation("1"), Ok(1));
    assert_eq!(parse_generation("9223372036854775807"), Ok(i64::MAX));
    for invalid in [
        "",
        "00",
        "01",
        "+1",
        "-1",
        " 1",
        "1 ",
        "1.0",
        "1e0",
        "１",
        "9223372036854775808",
        "99999999999999999999",
    ] {
        assert!(parse_generation(invalid).is_err(), "accepted {invalid:?}");
    }
}
