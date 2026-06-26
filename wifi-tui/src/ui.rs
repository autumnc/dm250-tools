use crate::app::{App, FormField, Screen};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
    Frame,
};

const HIGHLIGHT_STYLE: Style = Style::new().bg(Color::DarkGray);
const ERROR_STYLE: Style = Style::new().fg(Color::Red);
const STATUS_STYLE: Style = Style::new().fg(Color::Cyan);
const HELP_STYLE: Style = Style::new().fg(Color::DarkGray);
const TITLE_STYLE: Style = Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD);

pub fn draw(f: &mut Frame, app: &mut App) {
    let area = f.area();

    // Ensure minimum size
    if area.width < 40 || area.height < 8 {
        let msg = Paragraph::new("Terminal too small.\nNeed at least 40x8.")
            .style(ERROR_STYLE)
            .centered();
        f.render_widget(msg, area);
        return;
    }

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(3),
            Constraint::Length(1),
        ])
        .split(area);

    match app.screen {
        Screen::MainMenu => draw_main_menu(f, chunks[0], app),
        Screen::ScanResults => draw_scan_results(f, chunks[0], app),
        Screen::SavedNetworks => draw_saved_networks(f, chunks[0], app),
        Screen::AddNetwork => draw_add_network(f, chunks[0], app),
        Screen::Status => draw_detail(f, chunks[0], app, "WiFi Status"),
        Screen::IPAddresses => draw_detail(f, chunks[0], app, "IP Addresses"),
        Screen::ConfigViewer => draw_detail(f, chunks[0], app, "Config File"),
    }

    draw_status_bar(f, chunks[1], app);
}

// ---- Main Menu ----

fn draw_main_menu(f: &mut Frame, area: Rect, app: &mut App) {
    let items: Vec<ListItem> = app
        .menu_items()
        .iter()
        .enumerate()
        .map(|(i, label)| {
            let prefix = if i == app.menu_selection { " > " } else { "   " };
            let text = format!("{}{}. {}", prefix, i + 1, label);
            if i == app.menu_selection {
                ListItem::new(text).style(HIGHLIGHT_STYLE)
            } else {
                ListItem::new(text)
            }
        })
        .collect();

    let list = List::new(items)
        .block(
            Block::default()
                .title(Span::styled(" WiFi Manager ", TITLE_STYLE))
                .borders(Borders::ALL),
        );

    f.render_stateful_widget(list, area, &mut app.list_state);

    // Bottom help
    let help_area = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(0),
            Constraint::Length(1),
        ])
        .split(area)[1];

    let help = Span::styled(
        "Enter: select  j/k: navigate  1-9: quick  q: quit",
        HELP_STYLE,
    );
    f.render_widget(Paragraph::new(help), help_area);
}

// ---- Scan Results ----

fn draw_scan_results(f: &mut Frame, area: Rect, app: &mut App) {
    if app.scan_results.is_empty() {
        let msg = Paragraph::new("No networks found.")
            .block(Block::default().borders(Borders::ALL).title(" Scan Results "))
            .centered();
        f.render_widget(msg, area);
        return;
    }

    let items: Vec<ListItem> = app
        .scan_results
        .iter()
        .enumerate()
        .map(|(i, net)| {
            let bars = signal_bars(net.signal);
            let style = signal_style(net.signal);
            let sec_label = crate::app::detect_security(&net.flags).label().to_string();

            let line = Line::from(vec![
                Span::raw(if i == app.menu_selection { " > " } else { "   " }),
                Span::styled(bars, style),
                Span::raw(format!(" {:3} dBm  ", net.signal)),
                Span::styled(sec_label, style),
                Span::raw("  "),
                Span::raw(&net.ssid),
            ]);

            if i == app.menu_selection {
                ListItem::new(line).style(HIGHLIGHT_STYLE)
            } else {
                ListItem::new(line)
            }
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .title(format!(
                " Scan Results ({}) ",
                app.scan_results.len()
            ))
            .borders(Borders::ALL),
    );

    f.render_stateful_widget(list, area, &mut app.list_state);

    // Help
    let help_area = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(area)[1];

    let help = Span::styled(
        "Enter: connect  a: add new  j/k: navigate  Esc: back",
        HELP_STYLE,
    );
    f.render_widget(Paragraph::new(help), help_area);
}

// ---- Saved Networks ----

fn draw_saved_networks(f: &mut Frame, area: Rect, app: &mut App) {
    if app.saved_networks.is_empty() {
        let msg = Paragraph::new("No saved networks.")
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(" Saved Networks "),
            )
            .centered();
        f.render_widget(msg, area);
        return;
    }

    let items: Vec<ListItem> = app
        .saved_networks
        .iter()
        .enumerate()
        .map(|(i, net)| {
            let id_str = format!("[{:>2}]", net.id);
            let flag_info = if net.flags.contains("CURRENT") {
                Span::styled(" [CONNECTED]", Style::new().fg(Color::Green))
            } else if net.flags.contains("DISABLED") {
                Span::styled(" [DISABLED]", Style::new().fg(Color::Yellow))
            } else {
                Span::raw("")
            };

            let prefix = if i == app.menu_selection { " > " } else { "   " };
            let line = Line::from(vec![
                Span::raw(prefix),
                Span::raw(id_str),
                Span::raw(" "),
                Span::raw(&net.ssid),
                flag_info,
            ]);

            if i == app.menu_selection {
                ListItem::new(line).style(HIGHLIGHT_STYLE)
            } else {
                ListItem::new(line)
            }
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .title(format!(
                " Saved Networks ({}) ",
                app.saved_networks.len()
            ))
            .borders(Borders::ALL),
    );

    f.render_stateful_widget(list, area, &mut app.list_state);

    // Help
    let help_area = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(area)[1];

    let help = Span::styled(
        "Enter: connect  e: edit  d/Del: delete  j/k: navigate  Esc: back",
        HELP_STYLE,
    );
    f.render_widget(Paragraph::new(help), help_area);
}

// ---- Add Network Form ----

fn draw_add_network(f: &mut Frame, area: Rect, app: &App) {
    let title = if app.editing_network_id.is_some() {
        " Edit Network "
    } else {
        " Add Network "
    };

    let block = Block::default().title(title).borders(Borders::ALL);
    let inner = block.inner(area);
    f.render_widget(block, area);

    let field_height = 2; // label + input line
    let visible = FormField::visible_fields(app.add_form.security);
    let total_height = visible.len() as u16 * field_height + 2;

    let form_area = Rect {
        x: inner.x + 2,
        y: inner.y + 1,
        width: (inner.width - 4).min(60),
        height: total_height,
    };

    let mut y = form_area.y;

    for field in &visible {
        let is_selected = *field == app.add_form.selected_field;

        // Label
        let label = match field {
            FormField::Ssid => "SSID:",
            FormField::Security => "Security:",
            FormField::Password => "Password:",
            FormField::Identity => "Identity:",
            FormField::Save => "",
            FormField::Cancel => "",
        };

        if *field == FormField::Save || *field == FormField::Cancel {
            draw_form_buttons(f, form_area, y, app, is_selected);
            break;
        }

        let label_style = if is_selected {
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };

        f.render_widget(
            Paragraph::new(Span::styled(label, label_style)),
            Rect::new(form_area.x, y, form_area.width, 1),
        );

        y += 1;

        // Value
        let value_text = match field {
            FormField::Ssid => app.add_form.ssid.clone(),
            FormField::Password => {
                if app.add_form.show_password {
                    app.add_form.password.clone()
                } else {
                    "•".repeat(app.add_form.password.len())
                }
            }
            FormField::Identity => app.add_form.identity.clone(),
            FormField::Security => app.add_form.security.label().to_string(),
            _ => String::new(),
        };

        let field_rect = Rect::new(form_area.x + 2, y, form_area.width - 4, 1);

        if is_selected {
            let text = if value_text.is_empty() {
                format!("[{}]", " ".repeat(20))
            } else {
                format!("[{}]", value_text)
            };
            f.render_widget(
                Paragraph::new(text).style(HIGHLIGHT_STYLE),
                field_rect,
            );

            // Show cursor for text fields
            if matches!(*field, FormField::Ssid | FormField::Password | FormField::Identity) {
                let cursor_x = field_rect.x + 1 + app.add_form.cursor as u16;
                if cursor_x < field_rect.x + field_rect.width {
                    f.render_widget(
                        Paragraph::new(Span::styled(
                            " ",
                            Style::default()
                                .bg(Color::White)
                                .add_modifier(Modifier::UNDERLINED),
                        )),
                        Rect::new(cursor_x, field_rect.y, 1, 1),
                    );
                }
            }
        } else {
            let display = if value_text.is_empty() {
                "[                    ]".to_string()
            } else {
                format!("[ {} ]", value_text)
            };
            let style = match field {
                FormField::Security => Style::default().fg(Color::Yellow),
                _ => Style::default(),
            };
            f.render_widget(Paragraph::new(Span::styled(display, style)), field_rect);
        }

        y += 1;
    }
}

fn draw_form_buttons(f: &mut Frame, area: Rect, y: u16, app: &App, _is_button_row: bool) {
    let save_style = if app.add_form.selected_field == FormField::Save {
        Style::default().bg(Color::DarkGray).add_modifier(Modifier::BOLD)
    } else {
        Style::default()
    };

    let cancel_style = if app.add_form.selected_field == FormField::Cancel {
        Style::default().bg(Color::DarkGray).add_modifier(Modifier::BOLD)
    } else {
        Style::default()
    };

    let btn_width = 12;
    let gap = 4;
    let total_width = btn_width * 2 + gap;
    let start_x = area.x + (area.width.saturating_sub(total_width)) / 2;

    f.render_widget(
        Paragraph::new(Span::styled("[  Save  ]", save_style)),
        Rect::new(start_x, y, btn_width, 1),
    );

    f.render_widget(
        Paragraph::new(Span::styled("[ Cancel ]", cancel_style)),
        Rect::new(start_x + btn_width + gap, y, btn_width, 1),
    );

    if app.add_form.selected_field == FormField::Save || app.add_form.selected_field == FormField::Cancel {
        let help_text = "Tab: next field  Esc: back";
        f.render_widget(
            Paragraph::new(Span::styled(help_text, HELP_STYLE)),
            Rect::new(start_x, y + 1, total_width, 1),
        );
    }
}

// ---- Detail Screens (Status, IP, Config) ----

fn draw_detail(f: &mut Frame, area: Rect, app: &App, title: &str) {
    let lines: Vec<Line> = app
        .detail_text
        .lines()
        .skip(app.detail_scroll)
        .map(|l| Line::from(l.to_string()))
        .collect();

    let _content_height = area.height.saturating_sub(3);
    let total_lines = app.detail_text.lines().count();

    let scroll_info = if total_lines > 0 {
        let pct = (app.detail_scroll as f64 / total_lines as f64 * 100.0) as u16;
        format!(" {}% ", pct)
    } else {
        String::new()
    };

    let p = Paragraph::new(lines)
        .block(
            Block::default()
                .title(format!(" {} {}", title, scroll_info))
                .borders(Borders::ALL),
        )
        .wrap(Wrap { trim: true });

    f.render_widget(p, area);

    let help_area = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(area)[1];

    let help = Span::styled("j/k: scroll  PgUp/PgDn: page  any other key: back", HELP_STYLE);
    f.render_widget(Paragraph::new(help), help_area);
}

// ---- Interface Select ----

// ---- Status Bar ----

fn draw_status_bar(f: &mut Frame, area: Rect, app: &App) {
    let left = Span::styled(
        format!(" WiFi: {} | Interface: {} ", app.wifi_state_label(), app.interface),
        STATUS_STYLE,
    );

    let right = if !app.error_message.is_empty() {
        Span::styled(&app.error_message, ERROR_STYLE)
    } else if !app.status_message.is_empty() {
        Span::styled(&app.status_message, STATUS_STYLE)
    } else {
        let label = match app.screen {
            Screen::MainMenu => "Main Menu",
            Screen::ScanResults => "Scan Results",
            Screen::SavedNetworks => "Saved Networks",
            Screen::AddNetwork => "Add Network",
            Screen::Status => "WiFi Status",
            Screen::IPAddresses => "IP Addresses",
            Screen::ConfigViewer => "Config Viewer",
        };
        Span::styled(label, HELP_STYLE)
    };

    let bar = Line::from(vec![left, Span::raw(" "), right]);
    f.render_widget(Paragraph::new(bar), area);
}

// ---- Signal strength display ----

fn signal_bars(signal: i32) -> String {
    // Map -90..-30 dBm to 0..10 bars
    let level = ((signal + 90).clamp(0, 60) as f32 / 6.0).ceil() as usize;
    let level = level.min(10);
    let filled = "█".repeat(level);
    let empty = "░".repeat(10 - level);
    format!("{}{}", filled, empty)
}

fn signal_style(signal: i32) -> Style {
    match signal {
        s if s >= -50 => Style::default().fg(Color::Green),
        s if s >= -65 => Style::default().fg(Color::Yellow),
        _ => Style::default().fg(Color::Red),
    }
}
