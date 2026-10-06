//! HyperEnv's core: everything that decides *what* to do with environment
//! variables, with no I/O.
//!
//! A profile is a batch of variables. Applying writes the batch so every new
//! terminal starts with it; un-applying puts each variable back to the value it
//! had before — not merely unsets it. This crate is the same logic for macOS
//! (through FFI), Linux and Windows; the engine layer on top of it is what
//! touches the disk, the shell and the registry.

pub mod dotenv;
pub mod guarded_block;
pub mod probe;
pub mod quoting;
pub mod reconcile;
pub mod render;
pub mod seed;
pub mod types;

pub use types::{EnvKey, EnvSet, EnvValue, Error, PriorState};
