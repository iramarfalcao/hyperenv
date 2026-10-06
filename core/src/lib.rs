//! Núcleo do HyperEnv: tudo o que decide *o que* fazer com as variáveis de
//! ambiente, sem fazer I/O.
//!
//! Um perfil é um lote de variáveis. Aplicar escreve o lote para que todo
//! terminal novo nasça com ele; desfazer devolve cada variável ao valor que
//! tinha antes — não só apaga. Este crate é a mesma lógica para macOS (via
//! FFI), Linux e Windows; quem toca disco, shell e registro é a camada de
//! motor, por cima dele.

pub mod dotenv;
pub mod guarded_block;
pub mod probe;
pub mod quoting;
pub mod reconcile;
pub mod render;
pub mod seed;
pub mod types;

pub use types::{EnvKey, EnvSet, EnvValue, Error, PriorState};
