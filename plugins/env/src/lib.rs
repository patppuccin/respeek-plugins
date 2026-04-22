use extism_pdk::*;
use serde::{Deserialize, Serialize};
use serde_json;
use std::collections::HashMap;

#[derive(Serialize, Deserialize)]
struct FunctionSchema {
    #[serde(skip_serializing_if = "Option::is_none")]
    input: Option<String>,
    returns: String,
    description: String,
}

#[derive(Serialize, Deserialize)]
struct Capabilities {
    env: bool,
    network: bool,
    sockets: bool,
    filesystem: bool,
    exec: bool,
    system_info: bool,
    clock: bool,
}

#[derive(Serialize, Deserialize)]
struct PluginSchema {
    namespace: String,
    version: String,
    capabilities: Capabilities,
    functions: HashMap<String, FunctionSchema>,
}

fn plugin_version() -> &'static str {
    option_env!("RESPEEK_PLUGIN_VERSION").unwrap_or("dev")
}

#[plugin_fn]
pub fn version(_: ()) -> FnResult<String> {
    Ok(plugin_version().to_string())
}

#[plugin_fn]
pub fn schema(_: ()) -> FnResult<String> {
    let mut functions = HashMap::new();

    functions.insert(
        "all".to_string(),
        FunctionSchema {
            input: None,
            returns: "Record<string, string>".to_string(),
            description: "Returns all environment variables as a key-value object".to_string(),
        },
    );

    functions.insert(
        "get".to_string(),
        FunctionSchema {
            input: Some("string".to_string()),
            returns: "string | null".to_string(),
            description: "Returns the value of a single environment variable".to_string(),
        },
    );

    let schema = PluginSchema {
        namespace: "env".to_string(),
        version: plugin_version().to_string(),
        capabilities: Capabilities {
            env: true,
            network: false,
            sockets: false,
            filesystem: false,
            exec: false,
            system_info: false,
            clock: false,
        },
        functions,
    };

    Ok(serde_json::to_string(&schema)?)
}

#[plugin_fn]
pub fn all(_: ()) -> FnResult<Json<HashMap<String, String>>> {
    let map: HashMap<String, String> = std::env::vars().collect();
    Ok(Json(map))
}

#[plugin_fn]
pub fn get(key: String) -> FnResult<Option<String>> {
    Ok(std::env::var(&key).ok())
}