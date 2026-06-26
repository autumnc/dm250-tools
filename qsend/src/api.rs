use md5::{Digest, Md5};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const API_BASE: &str = "https://flomoapp.com/api/v1";
const API_KEY: &str = "flomo_web";
const APP_VERSION: &str = "4.0";
const PLATFORM: &str = "web";
const SIGN_SECRET: &str = "dbbc3dd73364b4084c3a69346e0ce2b2";
const TIMEZONE: &str = "8:0";

fn config_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".flomo-cli")
}

fn token_path() -> PathBuf {
    config_dir().join("token.json")
}

pub fn load_token() -> Option<String> {
    let path = token_path();
    if !path.exists() {
        return None;
    }
    let data: Value =
        serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    data.get("access_token")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

pub fn save_token_to_file(data: &Value) {
    let dir = config_dir();
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(
        token_path(),
        serde_json::to_string_pretty(data).unwrap_or_default(),
    );
}

pub fn clear_token_file() {
    let _ = std::fs::remove_file(token_path());
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

fn base_params() -> HashMap<String, String> {
    let mut p = HashMap::new();
    p.insert("timestamp".into(), timestamp());
    p.insert("api_key".into(), API_KEY.into());
    p.insert("app_version".into(), APP_VERSION.into());
    p.insert("platform".into(), PLATFORM.into());
    p.insert("webp".into(), "1".into());
    p
}

fn generate_sign(params: &HashMap<String, String>) -> String {
    let mut keys: Vec<&String> = params.keys().collect();
    keys.sort();
    let parts: Vec<String> = keys
        .iter()
        .filter_map(|k| {
            let v = params.get(*k)?;
            if v.is_empty() {
                return None;
            }
            Some(format!("{}={}", k, v))
        })
        .collect();
    let raw = format!("{}{}", parts.join("&"), SIGN_SECRET);
    let mut hasher = Md5::new();
    hasher.update(raw.as_bytes());
    format!("{:x}", hasher.finalize())
}

pub struct FlomoClient {
    client: Client,
    token: String,
}

impl FlomoClient {
    pub fn new(token: &str) -> Self {
        Self {
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
            token: token.to_string(),
        }
    }

    pub async fn login(email: &str, password: &str) -> Result<Value, String> {
        let mut params: HashMap<String, String> = HashMap::new();
        params.insert("email".into(), email.into());
        params.insert("password".into(), password.into());
        params.insert("wechat_union_id".into(), String::new());
        params.insert("wechat_oa_open_id".into(), String::new());
        params.insert("timestamp".into(), timestamp());
        params.insert("api_key".into(), API_KEY.into());
        params.insert("app_version".into(), APP_VERSION.into());
        params.insert("platform".into(), PLATFORM.into());
        params.insert("webp".into(), "1".into());
        let sign = generate_sign(&params);
        params.insert("sign".into(), sign);

        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap_or_default();

        let resp = client
            .post(format!("{}/user/login_by_email", API_BASE))
            .json(&params)
            .send()
            .await
            .map_err(|e| format!("网络错误: {}", e))?;
        handle_response(resp).await
    }

    pub async fn create_memo(&self, content: &str) -> Result<Memo, String> {
        let mut params = base_params();
        params.insert("content".into(), text_to_html(content));
        params.insert("source".into(), "web".into());
        params.insert("tz".into(), TIMEZONE.into());
        let sign = generate_sign(&params);
        params.insert("sign".into(), sign);

        let resp = self
            .client
            .put(format!("{}/memo", API_BASE))
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Content-Type", "application/json")
            .json(&params)
            .send()
            .await
            .map_err(|e| format!("网络错误: {}", e))?;

        let result = handle_response(resp).await?;
        serde_json::from_value(result).map_err(|e| e.to_string())
    }
}

async fn handle_response(resp: reqwest::Response) -> Result<Value, String> {
    let body: Value = resp
        .json()
        .await
        .map_err(|e| format!("无效的JSON响应: {}", e))?;
    let code = body.get("code").and_then(|v| v.as_i64()).unwrap_or(-1);
    let message = body
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if code == 0 {
        return Ok(body.get("data").cloned().unwrap_or(body));
    }
    if code == -10 || code == -20 {
        return Err(format!("Token已过期，请重新登录: {}", message));
    }
    Err(format!("API错误(code={}): {}", code, message))
}

fn text_to_html(text: &str) -> String {
    if text.starts_with('<') {
        return text.to_string();
    }
    text.split('\n')
        .map(|line| {
            if line.trim().is_empty() {
                "<p><br></p>".to_string()
            } else {
                format!("<p>{}</p>", line)
            }
        })
        .collect::<Vec<_>>()
        .join("")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Memo {
    pub slug: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub tags: Vec<String>,
}
