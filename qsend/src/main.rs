mod api;
mod editor;

use std::io;

use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    prelude::*,
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Clear, Paragraph},
};
use unicode_width::UnicodeWidthStr;

use editor::Editor;

// ─── Theme ─────────────────────────────────────────────────────────────────

struct P {
    bg: Color,
    text: Color,
    subtext: Color,
    blue: Color,
    green: Color,
    red: Color,
    yellow: Color,
    dim: Color,
    overlay: Color,
    surface: Color,
    border: Color,
}

const P: P = P {
    bg: Color::Reset,
    text: Color::Rgb(192, 202, 245),
    subtext: Color::Rgb(86, 95, 137),
    blue: Color::Rgb(122, 162, 247),
    green: Color::Rgb(158, 206, 106),
    red: Color::Rgb(247, 118, 142),
    yellow: Color::Rgb(224, 175, 104),
    dim: Color::Rgb(86, 95, 137),
    overlay: Color::Reset,
    surface: Color::Reset,
    border: Color::Rgb(56, 58, 89),
};

// ─── App State ─────────────────────────────────────────────────────────────

enum Mode {
    Login {
        email: String,
        password: String,
        step: LoginStep,
        error: Option<String>,
        loading: bool,
    },
    Editor,
}

#[derive(Clone, Copy, PartialEq)]
enum LoginStep {
    Email,
    Password,
}

#[derive(Clone, Copy, PartialEq)]
enum StatusKind {
    Success,
    Error,
    Info,
}

struct App {
    mode: Mode,
    editor: Editor,
    token: Option<String>,
    status_text: Option<String>,
    status_kind: StatusKind,
}

// ─── Main ──────────────────────────────────────────────────────────────────

fn main() -> io::Result<()> {
    // Terminal setup
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Load saved token
    let token = api::load_token();
    let has_token = token.is_some();

    let mut app = App {
        mode: if has_token {
            Mode::Editor
        } else {
            Mode::Login {
                email: String::new(),
                password: String::new(),
                step: LoginStep::Email,
                error: None,
                loading: false,
            }
        },
        editor: Editor::new(),
        token,
        status_text: if has_token {
            None
        } else {
            None
        },
        status_kind: StatusKind::Info,
    };

    // Tokio runtime for API calls
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    // Event loop
    loop {
        terminal.draw(|f| draw(f, &mut app))?;

        if event::poll(std::time::Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                let should_quit = handle_key(&mut app, &rt, &mut terminal, key)?;
                if should_quit {
                    break;
                }
            }
        }
    }

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    Ok(())
}

fn handle_key(
    app: &mut App,
    rt: &tokio::runtime::Runtime,
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    key: KeyEvent,
) -> io::Result<bool> {
    match &mut app.mode {
        Mode::Login {
            email,
            password,
            step,
            error,
            loading,
        } => {
            if *loading {
                return Ok(false);
            }
            match key {
                KeyEvent {
                    code: KeyCode::Esc, ..
                }
                | KeyEvent {
                    code: KeyCode::Char('q'),
                    modifiers: KeyModifiers::CONTROL,
                    ..
                } => return Ok(true),
                KeyEvent {
                    code: KeyCode::Tab, ..
                } => {
                    *step = match step {
                        LoginStep::Email => LoginStep::Password,
                        LoginStep::Password => LoginStep::Email,
                    };
                }
                KeyEvent {
                    code: KeyCode::Enter, ..
                } => {
                    if email.is_empty() || password.is_empty() {
                        *error = Some("邮箱和密码不能为空".into());
                    } else {
                        *loading = true;
                        *error = None;
                        let e = email.clone();
                        let p = password.clone();
                        match rt.block_on(api::FlomoClient::login(&e, &p)) {
                            Ok(data) => {
                                let tk = data
                                    .get("access_token")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                api::save_token_to_file(&data);
                                app.token = Some(tk);
                                app.mode = Mode::Editor;
                                app.status_text = Some("已登录，开始书写吧".into());
                                app.status_kind = StatusKind::Success;
                            }
                            Err(e) => {
                                *loading = false;
                                *error = Some(e);
                            }
                        }
                    }
                }
                KeyEvent {
                    code: KeyCode::Char(c),
                    modifiers: KeyModifiers::NONE | KeyModifiers::SHIFT,
                    ..
                } => match step {
                    LoginStep::Email => email.push(c),
                    LoginStep::Password => password.push(c),
                },
                KeyEvent {
                    code: KeyCode::Backspace,
                    ..
                } => match step {
                    LoginStep::Email => {
                        email.pop();
                    }
                    LoginStep::Password => {
                        password.pop();
                    }
                },
                _ => {}
            }
        }
        Mode::Editor => match key {
            KeyEvent {
                code: KeyCode::Esc, ..
            }
            | KeyEvent {
                code: KeyCode::Char('q'),
                modifiers: KeyModifiers::CONTROL,
                ..
            }
            | KeyEvent {
                code: KeyCode::Char('c'),
                modifiers: KeyModifiers::CONTROL,
                ..
            } => return Ok(true),
            KeyEvent {
                code: KeyCode::Char('s'),
                modifiers: KeyModifiers::CONTROL,
                ..
            } => {
                let content = app.editor.text();
                if content.trim().is_empty() {
                    app.status_text = Some("内容为空，请输入笔记内容".into());
                    app.status_kind = StatusKind::Error;
                } else if app.token.is_some() {
                    let tk = app.token.clone().unwrap();
                    app.status_text = Some("发送中...".into());
                    app.status_kind = StatusKind::Info;
                    terminal.draw(|f| draw(f, app))?;

                    let client = api::FlomoClient::new(&tk);
                    match rt.block_on(client.create_memo(&content)) {
                        Ok(_) => return Ok(true),
                        Err(e) => {
                            if e.contains("Token已过期") {
                                api::clear_token_file();
                                app.token = None;
                                app.mode = Mode::Login {
                                    email: String::new(),
                                    password: String::new(),
                                    step: LoginStep::Email,
                                    error: Some("Token已过期，请重新登录".into()),
                                    loading: false,
                                };
                            } else {
                                app.status_text =
                                    Some(format!("发送失败: {}", e));
                                app.status_kind = StatusKind::Error;
                            }
                        }
                    }
                } else {
                    app.mode = Mode::Login {
                        email: String::new(),
                        password: String::new(),
                        step: LoginStep::Email,
                        error: None,
                        loading: false,
                    };
                }
            }
            _ => {
                app.status_text = None;
                app.editor.handle_key(key);
            }
        },
    }
    Ok(false)
}

// ─── Drawing ───────────────────────────────────────────────────────────────

fn draw(f: &mut Frame, app: &mut App) {
    let size = f.area();
    f.render_widget(Clear, size);

    match &app.mode {
        Mode::Login {
            email,
            password,
            step,
            error,
            loading,
        } => draw_login(f, size, email, password, *step, error, *loading),
        Mode::Editor => draw_editor(f, app, size),
    }
}

fn draw_login(
    f: &mut Frame,
    size: Rect,
    email: &str,
    password: &str,
    step: LoginStep,
    error: &Option<String>,
    loading: bool,
) {
    // Background
    f.render_widget(
        Paragraph::new("").style(Style::default().bg(P.bg)),
        size,
    );

    let w = 44u16.min(size.width.saturating_sub(4));
    let h = 14u16.min(size.height.saturating_sub(4));
    let x = size.width.saturating_sub(w) / 2;
    let y = size.height.saturating_sub(h) / 2;
    let area = Rect::new(x, y, w, h);

    let block = Block::default()
        .title(" qsend 登录 ")
        .title_style(
            Style::default()
                .fg(P.blue)
                .add_modifier(Modifier::BOLD),
        )
        .style(Style::default().bg(P.overlay).fg(P.text))
        .border_style(Style::default().fg(P.blue))
        .borders(Borders::ALL);

    let inner = block.inner(area);
    f.render_widget(block, area);

    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  登录 flomo 账号以发送笔记",
        Style::default().fg(P.dim),
    )));
    lines.push(Line::from(""));

    // Email field
    let email_style = if step == LoginStep::Email {
        Style::default().fg(P.yellow).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(P.dim)
    };
    let email_display = if step == LoginStep::Email {
        format!("{}▏", email)
    } else {
        email.to_string()
    };
    lines.push(Line::from(vec![
        Span::styled("  邮箱: ", email_style),
        Span::styled(email_display, Style::default().fg(P.text)),
    ]));
    lines.push(Line::from(""));

    // Password field
    let pwd_style = if step == LoginStep::Password {
        Style::default().fg(P.yellow).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(P.dim)
    };
    let pwd_display = "•".repeat(password.len());
    let pwd_display = if step == LoginStep::Password {
        format!("{}▏", pwd_display)
    } else {
        pwd_display
    };
    lines.push(Line::from(vec![
        Span::styled("  密码: ", pwd_style),
        Span::styled(pwd_display, Style::default().fg(P.text)),
    ]));

    // Loading / Error
    if loading {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "  登录中...",
            Style::default().fg(P.yellow),
        )));
    }
    if let Some(ref err) = error {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            format!("  ✗ {}", err),
            Style::default().fg(P.red),
        )));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  Tab 切换  Enter 登录  Ctrl+Q 退出",
        Style::default().fg(P.dim),
    )));

    let paragraph = Paragraph::new(lines);
    f.render_widget(paragraph, inner);

    // Cursor
    let (cx, cy) = if step == LoginStep::Email {
        (
            inner.x + 8 + UnicodeWidthStr::width(email) as u16,
            inner.y + 3,
        )
    } else {
        (
            inner.x + 8 + password.len() as u16,
            inner.y + 5,
        )
    };
    f.set_cursor_position(Position::new(cx, cy));
}

fn draw_editor(f: &mut Frame, app: &mut App, size: Rect) {
    let footer_h = 1u16;
    let main_h = size.height.saturating_sub(footer_h);
    let chunks = Layout::vertical([Constraint::Min(main_h), Constraint::Length(footer_h)]).split(size);

    draw_edit_area(f, app, chunks[0]);
    draw_status_bar(f, app, chunks[1]);
}

fn draw_edit_area(f: &mut Frame, app: &mut App, area: Rect) {
    let block = Block::default()
        .style(Style::default().bg(P.bg))
        .border_style(Style::default().fg(P.border));

    let inner = block.inner(area);
    f.render_widget(block, area);

    let max_w = inner.width.max(1) as usize;
    let visible = inner.height;

    app.editor.update_scroll(max_w, visible);

    let editor = &app.editor;

    // Build display lines with wrapping
    let mut display_lines: Vec<Line> = Vec::new();
    let mut visual_cursor_row = 0usize;
    let mut visual_cursor_col = 0usize;

    for (li, logical_line) in editor.lines.iter().enumerate() {
        let wrapped = editor::wrap_plain_text(logical_line, max_w);
        if li < editor.cursor_row {
            visual_cursor_row += wrapped.len();
        } else if li == editor.cursor_row {
            let line_up_to_cursor = &logical_line[..editor.cursor_byte];
            let display_col_before = UnicodeWidthStr::width(line_up_to_cursor);
            visual_cursor_col = display_col_before % max_w;
            visual_cursor_row += display_col_before / max_w;
        }
        for w in wrapped {
            display_lines.push(Line::from(w));
        }
    }

    if display_lines.is_empty() {
        display_lines.push(Line::from(""));
    }

    let text = Text::from(display_lines);

    let scroll = editor.scroll;
    let paragraph = Paragraph::new(text).scroll((scroll as u16, 0));
    f.render_widget(paragraph, inner);

    // Cursor
    let cx = inner.x + visual_cursor_col as u16;
    let cy = inner.y + visual_cursor_row as u16 - scroll as u16;
    f.set_cursor_position(Position::new(cx, cy));
}

fn draw_status_bar(f: &mut Frame, app: &App, area: Rect) {
    let text = app.editor.text();
    let char_count = text.chars().count();
    let line_count = app.editor.lines.len();
    let byte_count = text.len();

    let mut spans = vec![
        Span::styled(
            format!(" 字数: {} ", char_count),
            Style::default().fg(P.blue),
        ),
        Span::styled(
            format!("行数: {} ", line_count),
            Style::default().fg(P.subtext),
        ),
        Span::styled(
            format!("字节: {} ", byte_count),
            Style::default().fg(P.dim),
        ),
    ];

    // Status message
    if let Some(ref msg) = app.status_text {
        spans.push(Span::styled(
            format!("  {}", msg),
            Style::default().fg(match app.status_kind {
                StatusKind::Success => P.green,
                StatusKind::Error => P.red,
                StatusKind::Info => P.yellow,
            }),
        ));
    }

    // Shortcuts
    let shortcut_w = UnicodeWidthStr::width(" Ctrl+S 发送  Esc 退出");
    let padding = area.width as usize - shortcut_w;
    spans.push(Span::styled(
        format!(
            "{:>width$}",
            "Ctrl+S 发送  Esc 退出",
            width = shortcut_w + padding.saturating_sub(1),
        ),
        Style::default().fg(P.dim),
    ));

    let line = Line::from(spans);
    let paragraph = Paragraph::new(line).style(Style::default().bg(P.surface));
    f.render_widget(paragraph, area);
}
