use paranoid_identity_core::fixed_public_test_vector_document;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let document = fixed_public_test_vector_document()?;
    let json = serde_json::to_string_pretty(&document)?;
    println!("{json}");
    Ok(())
}
