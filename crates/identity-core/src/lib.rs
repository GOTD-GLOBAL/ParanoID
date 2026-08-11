#![forbid(unsafe_code)]
#![doc = "Experimental ParanoID identity key-hierarchy reference implementation."]
#![doc = "This crate is not an accepted production identity protocol."]

mod error;
mod hkdf_candidate;
mod slip10_candidate;
mod vector;

pub use error::IdentityError;
pub use vector::{
    DerivationCandidate, PublicIdentityVector, PublicTestVectorDocument, PublicTestVectorInput,
    TEST_VECTOR_SCHEMA_VERSION, derive_public_vector, fixed_public_test_vector_document,
};
