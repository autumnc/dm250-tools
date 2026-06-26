use crate::wifi;
use crossterm::event::KeyCode;
use ratatui::widgets::ListState;

#[derive(Clone, Copy, PartialEq)]
pub enum Screen {
    MainMenu,
    ScanResults,
    SavedNetworks,
    AddNetwork,
    Status,
    IPAddresses,
    ConfigViewer,
}

#[derive(Clone, Copy, PartialEq)]
pub enum SecurityType {
    Open,
    Wpa2Psk,
    WpaEnterprise,
}

impl SecurityType {
    pub fn label(&self) -> &str {
        match self {
            SecurityType::Open => "OPEN",
            SecurityType::Wpa2Psk => "WPA2-PSK",
            SecurityType::WpaEnterprise => "WPA-EAP PEAP",
        }
    }

    pub fn key(&self) -> &str {
        match self {
            SecurityType::Open => "open",
            SecurityType::Wpa2Psk => "wpa2",
            SecurityType::WpaEnterprise => "enterprise",
        }
    }

    pub fn cycle_next(&mut self) {
        *self = match self {
            SecurityType::Open => SecurityType::Wpa2Psk,
            SecurityType::Wpa2Psk => SecurityType::WpaEnterprise,
            SecurityType::WpaEnterprise => SecurityType::Open,
        };
    }

    pub fn cycle_prev(&mut self) {
        *self = match self {
            SecurityType::Open => SecurityType::WpaEnterprise,
            SecurityType::Wpa2Psk => SecurityType::Open,
            SecurityType::WpaEnterprise => SecurityType::Wpa2Psk,
        };
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum FormField {
    Ssid,
    Security,
    Password,
    Identity,
    Save,
    Cancel,
}

impl FormField {
    pub fn visible_fields(security: SecurityType) -> Vec<FormField> {
        let mut fields = vec![FormField::Ssid, FormField::Security];
        match security {
            SecurityType::Wpa2Psk => fields.push(FormField::Password),
            SecurityType::WpaEnterprise => {
                fields.push(FormField::Identity);
                fields.push(FormField::Password);
            }
            SecurityType::Open => {}
        }
        fields.push(FormField::Save);
        fields.push(FormField::Cancel);
        fields
    }

    pub fn next(self, security: SecurityType) -> FormField {
        let fields = Self::visible_fields(security);
        let idx = fields.iter().position(|f| *f == self).unwrap_or(0);
        fields[(idx + 1) % fields.len()]
    }

    pub fn prev(self, security: SecurityType) -> FormField {
        let fields = Self::visible_fields(security);
        let idx = fields.iter().position(|f| *f == self).unwrap_or(0);
        fields[(idx + fields.len() - 1) % fields.len()]
    }
}

pub struct AddNetworkForm {
    pub ssid: String,
    pub security: SecurityType,
    pub password: String,
    pub identity: String,
    pub show_password: bool,
    pub selected_field: FormField,
    pub cursor: usize,
}

impl AddNetworkForm {
    pub fn new() -> Self {
        AddNetworkForm {
            ssid: String::new(),
            security: SecurityType::Wpa2Psk,
            password: String::new(),
            identity: String::new(),
            show_password: false,
            selected_field: FormField::Ssid,
            cursor: 0,
        }
    }

    pub fn with_ssid(ssid: &str, security: SecurityType) -> Self {
        AddNetworkForm {
            ssid: ssid.to_string(),
            security,
            password: String::new(),
            identity: String::new(),
            show_password: false,
            selected_field: FormField::Ssid,
            cursor: ssid.len(),
        }
    }

    pub fn reset(&mut self) {
        self.ssid.clear();
        self.security = SecurityType::Wpa2Psk;
        self.password.clear();
        self.identity.clear();
        self.show_password = false;
        self.selected_field = FormField::Ssid;
        self.cursor = 0;
    }
}

pub struct App {
    pub screen: Screen,
    pub interface: String,

    pub list_state: ListState,
    pub menu_selection: usize,

    pub scan_results: Vec<wifi::ScanResult>,
    pub saved_networks: Vec<wifi::SavedNetwork>,

    pub add_form: AddNetworkForm,
    pub editing_network_id: Option<String>,

    pub status_message: String,
    pub error_message: String,

    pub detail_text: String,
    pub detail_scroll: usize,

    pub should_quit: bool,
}

impl App {
    pub fn new() -> Self {
        let interface = wifi::detect_interface();
        let wifi_on = wifi::is_powered_on();

        let mut app = App {
            screen: Screen::MainMenu,
            interface,
            list_state: ListState::default(),
            menu_selection: 0,
            scan_results: Vec::new(),
            saved_networks: Vec::new(),
            add_form: AddNetworkForm::new(),
            editing_network_id: None,
            status_message: if wifi_on {
                "WiFi is ON".to_string()
            } else {
                "WiFi is OFF".to_string()
            },
            error_message: String::new(),
            detail_text: String::new(),
            detail_scroll: 0,
            should_quit: false,
        };

        app.list_state.select(Some(0));
        app
    }

    pub fn wifi_on(&self) -> bool {
        wifi::is_powered_on()
    }

    pub fn set_status(&mut self, msg: &str) {
        self.status_message = msg.to_string();
        self.error_message.clear();
    }

    pub fn set_error(&mut self, msg: &str) {
        self.error_message = msg.to_string();
        self.status_message.clear();
    }

    pub fn clear_messages(&mut self) {
        self.status_message.clear();
        self.error_message.clear();
    }

    fn ensure_selection_in_range(&mut self, max: usize) {
        if max == 0 {
            self.menu_selection = 0;
            self.list_state.select(None);
            return;
        }
        if self.menu_selection >= max {
            self.menu_selection = max - 1;
        }
        self.list_state.select(Some(self.menu_selection));
    }

    // ---- Top-level key dispatch ----

    pub fn handle_key(&mut self, code: KeyCode) {
        self.error_message.clear();

        match code {
            KeyCode::Esc => {
                self.handle_esc();
                return;
            }
            _ => {}
        }

        match self.screen {
            Screen::MainMenu => self.handle_main_menu_key(code),
            Screen::ScanResults => self.handle_scan_results_key(code),
            Screen::SavedNetworks => self.handle_saved_networks_key(code),
            Screen::AddNetwork => self.handle_add_network_key(code),
            Screen::Status | Screen::IPAddresses | Screen::ConfigViewer => {
                self.handle_detail_key(code);
            }
        }
    }

    fn handle_esc(&mut self) {
        match self.screen {
            Screen::MainMenu => self.should_quit = true,
            _ => {
                self.screen = Screen::MainMenu;
                self.menu_selection = 0;
                self.list_state.select(Some(0));
            }
        }
    }

    // ---- Main Menu ----

    fn handle_main_menu_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Up | KeyCode::Char('k') => {
                if self.menu_selection > 0 {
                    self.menu_selection -= 1;
                } else {
                    self.menu_selection = 8;
                }
                self.list_state.select(Some(self.menu_selection));
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.menu_selection < 8 {
                    self.menu_selection += 1;
                } else {
                    self.menu_selection = 0;
                }
                self.list_state.select(Some(self.menu_selection));
            }
            KeyCode::Enter => {
                self.execute_main_menu_action();
            }
            KeyCode::Char(c) => {
                if let Some(n) = c.to_digit(10) {
                    if n >= 1 && n <= 9 {
                        self.menu_selection = (n - 1) as usize;
                        self.list_state.select(Some(self.menu_selection));
                        self.execute_main_menu_action();
                    }
                }
            }
            _ => {}
        }
    }

    fn execute_main_menu_action(&mut self) {
        match self.menu_selection {
            0 => self.toggle_wifi(),
            1 => self.start_scan(),
            2 => self.load_saved_networks(),
            3 => self.start_add_network(),
            4 => self.load_status(),
            5 => self.load_ip_addresses(),
            6 => self.load_config_viewer(),
            7 => self.reload_config_action(),
            8 => self.should_quit = true,
            _ => {}
        }
    }

    fn toggle_wifi(&mut self) {
        if self.wifi_on() {
            match wifi::power_off(&self.interface) {
                Ok(()) => self.set_status("WiFi turned OFF"),
                Err(e) => self.set_error(&format!("Failed: {}", e)),
            }
        } else {
            match wifi::power_on(&self.interface) {
                Ok(()) => self.set_status("WiFi turned ON"),
                Err(e) => self.set_error(&format!("Failed: {}", e)),
            }
        }
    }

    fn start_scan(&mut self) {
        if !self.wifi_on() {
            self.set_error("WiFi is off. Turn it on first.");
            return;
        }

        self.status_message = "Scanning...".to_string();

        match wifi::scan(&self.interface) {
            Ok(()) => match wifi::scan_results(&self.interface) {
                Ok(results) => {
                    self.scan_results = results;
                    self.menu_selection = 0;
                    self.list_state.select(Some(0));
                    self.screen = Screen::ScanResults;
                    self.set_status(&format!("{} networks found", self.scan_results.len()));
                }
                Err(e) => self.set_error(&format!("Scan results failed: {}", e)),
            },
            Err(e) => self.set_error(&format!("Scan failed: {}", e)),
        }
    }

    fn load_saved_networks(&mut self) {
        if !self.wifi_on() {
            self.set_error("WiFi is off. Turn it on first.");
            return;
        }

        match wifi::list_networks(&self.interface) {
            Ok(networks) => {
                self.saved_networks = networks;
                self.menu_selection = 0;
                self.ensure_selection_in_range(self.saved_networks.len());
                self.screen = Screen::SavedNetworks;
                self.set_status(&format!("{} saved networks", self.saved_networks.len()));
            }
            Err(e) => self.set_error(&format!("Failed to list networks: {}", e)),
        }
    }

    fn start_add_network(&mut self) {
        if !self.wifi_on() {
            self.set_error("WiFi is off. Turn it on first.");
            return;
        }

        self.add_form.reset();
        self.editing_network_id = None;
        self.screen = Screen::AddNetwork;
        self.clear_messages();
    }

    fn load_status(&mut self) {
        if !self.wifi_on() {
            self.set_error("WiFi is off. Turn it on first.");
            return;
        }

        match wifi::wifi_status_detail(&self.interface) {
            Ok(text) => {
                self.detail_text = text;
                self.detail_scroll = 0;
                self.screen = Screen::Status;
            }
            Err(e) => self.set_error(&format!("Failed: {}", e)),
        }
    }

    fn load_ip_addresses(&mut self) {
        match wifi::ip_addresses() {
            Ok(text) => {
                self.detail_text = text;
                self.detail_scroll = 0;
                self.screen = Screen::IPAddresses;
            }
            Err(e) => self.set_error(&format!("Failed: {}", e)),
        }
    }

    fn load_config_viewer(&mut self) {
        match wifi::read_config_file() {
            Ok(text) => {
                self.detail_text = text;
                self.detail_scroll = 0;
                self.screen = Screen::ConfigViewer;
            }
            Err(e) => self.set_error(&format!("Failed: {}", e)),
        }
    }

    fn reload_config_action(&mut self) {
        if !self.wifi_on() {
            self.set_error("WiFi is off. Turn it on first.");
            return;
        }

        match wifi::reload_config(&self.interface) {
            Ok(()) => self.set_status("Configuration reloaded"),
            Err(e) => self.set_error(&format!("Failed: {}", e)),
        }
    }

    // ---- Scan Results ----

    fn handle_scan_results_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.menu_selection > 0 {
                    self.menu_selection -= 1;
                } else {
                    self.menu_selection = self.scan_results.len().saturating_sub(1);
                }
                self.list_state.select(Some(self.menu_selection));
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let max = self.scan_results.len().saturating_sub(1);
                if self.menu_selection < max {
                    self.menu_selection += 1;
                } else {
                    self.menu_selection = 0;
                }
                self.list_state.select(Some(self.menu_selection));
            }
            KeyCode::Enter => {
                self.connect_to_scan_result();
            }
            KeyCode::Char('a') => {
                if let Some(result) = self.scan_results.get(self.menu_selection) {
                    let sec = detect_security(&result.flags);
                    self.add_form = AddNetworkForm::with_ssid(&result.ssid, sec);
                    self.editing_network_id = None;
                    self.screen = Screen::AddNetwork;
                    self.clear_messages();
                }
            }
            _ => {}
        }
    }

    fn connect_to_scan_result(&mut self) {
        if let Some(result) = self.scan_results.get(self.menu_selection) {
            let ssid = result.ssid.clone();
            match wifi::find_network_by_ssid(&self.interface, &ssid) {
                Ok(Some(id)) => {
                    let _ = wifi::enable_network(&self.interface, &id);
                    match wifi::select_network(&self.interface, &id) {
                        Ok(()) => {
                            self.set_status(&format!("Connecting to {}...", ssid));
                            self.screen = Screen::MainMenu;
                            self.menu_selection = 0;
                            self.list_state.select(Some(0));
                        }
                        Err(e) => self.set_error(&format!("Failed: {}", e)),
                    }
                }
                _ => {
                    let sec = detect_security(&result.flags);
                    self.add_form = AddNetworkForm::with_ssid(&ssid, sec);
                    self.editing_network_id = None;
                    self.screen = Screen::AddNetwork;
                    self.clear_messages();
                }
            }
        }
    }

    // ---- Saved Networks ----

    fn handle_saved_networks_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.menu_selection > 0 {
                    self.menu_selection -= 1;
                } else {
                    self.menu_selection = self.saved_networks.len().saturating_sub(1);
                }
                self.ensure_selection_in_range(self.saved_networks.len());
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let max = self.saved_networks.len().saturating_sub(1);
                if self.menu_selection < max {
                    self.menu_selection += 1;
                } else {
                    self.menu_selection = 0;
                }
                self.ensure_selection_in_range(self.saved_networks.len());
            }
            KeyCode::Enter => {
                if let Some(net) = self.saved_networks.get(self.menu_selection) {
                    let id = net.id.clone();
                    let ssid = net.ssid.clone();
                    let _ = wifi::enable_network(&self.interface, &id);
                    match wifi::select_network(&self.interface, &id) {
                        Ok(()) => {
                            self.set_status(&format!("Connecting to {}...", ssid));
                            self.screen = Screen::MainMenu;
                            self.menu_selection = 0;
                            self.list_state.select(Some(0));
                        }
                        Err(e) => self.set_error(&format!("Failed: {}", e)),
                    }
                }
            }
            KeyCode::Delete | KeyCode::Char('d') => {
                self.delete_saved_network();
            }
            KeyCode::Char('e') => {
                if let Some(net) = self.saved_networks.get(self.menu_selection) {
                    self.add_form = AddNetworkForm::with_ssid(
                        &net.ssid,
                        SecurityType::Wpa2Psk,
                    );
                    self.editing_network_id = Some(net.id.clone());
                    self.screen = Screen::AddNetwork;
                    self.clear_messages();
                }
            }
            _ => {}
        }
    }

    fn delete_saved_network(&mut self) {
        if let Some(net) = self.saved_networks.get(self.menu_selection) {
            let id = net.id.clone();
            let ssid = net.ssid.clone();
            match wifi::remove_network(&self.interface, &id) {
                Ok(()) => {
                    let _ = wifi::save_config(&self.interface);
                    self.set_status(&format!("Deleted {}", ssid));
                    // Reload list
                    if let Ok(networks) = wifi::list_networks(&self.interface) {
                        self.saved_networks = networks;
                        self.ensure_selection_in_range(self.saved_networks.len());
                    }
                    if self.saved_networks.is_empty() {
                        self.screen = Screen::MainMenu;
                        self.menu_selection = 2;
                        self.list_state.select(Some(2));
                    }
                }
                Err(e) => self.set_error(&format!("Failed: {}", e)),
            }
        }
    }

    // ---- Add Network ----

    fn handle_add_network_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Tab => {
                self.add_form.selected_field =
                    self.add_form.selected_field.next(self.add_form.security);
                self.add_form.cursor = self.current_field_value().len();
            }
            KeyCode::BackTab => {
                self.add_form.selected_field =
                    self.add_form.selected_field.prev(self.add_form.security);
                self.add_form.cursor = self.current_field_value().len();
            }
            KeyCode::Enter => {
                if self.add_form.selected_field == FormField::Save {
                    self.save_network();
                } else if self.add_form.selected_field == FormField::Cancel {
                    self.screen = Screen::MainMenu;
                    self.menu_selection = 3;
                    self.list_state.select(Some(3));
                }
            }
            _ => self.handle_form_input(code),
        }
    }

    fn handle_form_input(&mut self, code: KeyCode) {
        match self.add_form.selected_field {
            FormField::Ssid => self.handle_text_input(code),
            FormField::Password => self.handle_text_input(code),
            FormField::Identity => self.handle_text_input(code),
            FormField::Security => match code {
                KeyCode::Left | KeyCode::Up => self.add_form.security.cycle_prev(),
                KeyCode::Right | KeyCode::Down => self.add_form.security.cycle_next(),
                _ => {}
            },
            FormField::Save | FormField::Cancel => {}
        }
    }

    fn handle_text_input(&mut self, code: KeyCode) {
        let field = self.add_form.selected_field;
        let cursor = self.add_form.cursor;

        let text = match field {
            FormField::Ssid => &mut self.add_form.ssid,
            FormField::Password => &mut self.add_form.password,
            FormField::Identity => &mut self.add_form.identity,
            _ => return,
        };

        let mut new_cursor = cursor;
        match code {
            KeyCode::Char(c) => {
                text.insert(cursor, c);
                new_cursor = (cursor + 1).min(text.len());
            }
            KeyCode::Backspace => {
                if cursor > 0 {
                    text.remove(cursor - 1);
                    new_cursor = cursor - 1;
                }
            }
            KeyCode::Delete => {
                if cursor < text.len() {
                    text.remove(cursor);
                }
            }
            KeyCode::Left => {
                if cursor > 0 {
                    new_cursor = cursor - 1;
                }
            }
            KeyCode::Right => {
                if cursor < text.len() {
                    new_cursor = cursor + 1;
                }
            }
            KeyCode::Home => new_cursor = 0,
            KeyCode::End => new_cursor = text.len(),
            _ => {}
        }
        self.add_form.cursor = new_cursor;
    }

    fn current_field_value(&self) -> &str {
        match self.add_form.selected_field {
            FormField::Ssid => &self.add_form.ssid,
            FormField::Password => &self.add_form.password,
            FormField::Identity => &self.add_form.identity,
            _ => "",
        }
    }

    fn save_network(&mut self) {
        let ssid = self.add_form.ssid.trim();
        if ssid.is_empty() {
            self.set_error("SSID cannot be empty");
            return;
        }

        match self.add_form.security {
            SecurityType::Wpa2Psk if self.add_form.password.is_empty() => {
                self.set_error("Password cannot be empty for WPA2-PSK");
                return;
            }
            SecurityType::WpaEnterprise => {
                if self.add_form.identity.is_empty() {
                    self.set_error("Identity cannot be empty for WPA-Enterprise");
                    return;
                }
                if self.add_form.password.is_empty() {
                    self.set_error("Password cannot be empty for WPA-Enterprise");
                    return;
                }
            }
            _ => {}
        }

        match wifi::add_network_to_config(
            &self.interface,
            ssid,
            self.add_form.security.key(),
            &self.add_form.password,
            &self.add_form.identity,
        ) {
            Ok(()) => {
                self.set_status(&format!("Network '{}' saved", ssid));
                self.screen = Screen::MainMenu;
                self.menu_selection = 3;
                self.list_state.select(Some(3));
            }
            Err(e) => self.set_error(&format!("Failed: {}", e)),
        }
    }

    // ---- Detail screens (Status, IP, Config) ----

    fn handle_detail_key(&mut self, code: KeyCode) {
        match code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.detail_scroll > 0 {
                    self.detail_scroll -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.detail_scroll += 1;
            }
            KeyCode::PageUp => {
                self.detail_scroll = self.detail_scroll.saturating_sub(10);
            }
            KeyCode::PageDown => {
                self.detail_scroll += 10;
            }
            _ => {
                self.screen = Screen::MainMenu;
                self.menu_selection = 0;
                self.list_state.select(Some(0));
            }
        }
    }

    // ---- Helpers ----

    pub fn menu_items(&self) -> &[&str] {
        &[
            "Turn WiFi On/Off",
            "Scan for Networks",
            "Saved Networks",
            "Add Network",
            "Connection Status",
            "IP Addresses",
            "View Config File",
            "Reload Configuration",
            "Quit",
        ]
    }

    pub fn wifi_state_label(&self) -> &str {
        if self.wifi_on() { "ON" } else { "OFF" }
    }
}

pub fn detect_security(flags: &str) -> SecurityType {
    if flags.contains("WPA") || flags.contains("RSN") {
        if flags.contains("EAP") {
            SecurityType::WpaEnterprise
        } else {
            SecurityType::Wpa2Psk
        }
    } else {
        SecurityType::Open
    }
}
