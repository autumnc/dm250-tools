use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub struct Editor {
    pub lines: Vec<String>,
    pub cursor_row: usize,
    pub cursor_byte: usize, // byte offset within current line
    pub scroll: usize,      // first visible logical line
    prefer_col: usize,      // preferred display column for up/down movement
}

impl Editor {
    pub fn new() -> Self {
        Self {
            lines: vec![String::new()],
            cursor_row: 0,
            cursor_byte: 0,
            scroll: 0,
            prefer_col: 0,
        }
    }

    pub fn text(&self) -> String {
        self.lines.join("\n")
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        match key {
            KeyEvent {
                code: KeyCode::Char(c),
                modifiers: KeyModifiers::NONE | KeyModifiers::SHIFT,
                ..
            } => self.insert_char(c),
            KeyEvent {
                code: KeyCode::Enter,
                ..
            } => self.newline(),
            KeyEvent {
                code: KeyCode::Backspace,
                ..
            } => self.delete_backward(),
            KeyEvent {
                code: KeyCode::Delete,
                ..
            } => self.delete_forward(),
            KeyEvent {
                code: KeyCode::Left,
                ..
            } => self.move_left(),
            KeyEvent {
                code: KeyCode::Right,
                ..
            } => self.move_right(),
            KeyEvent {
                code: KeyCode::Up,
                ..
            } => self.move_up(),
            KeyEvent {
                code: KeyCode::Down,
                ..
            } => self.move_down(),
            KeyEvent {
                code: KeyCode::Home,
                ..
            } => self.move_home(),
            KeyEvent {
                code: KeyCode::End,
                ..
            } => self.move_end(),
            KeyEvent {
                code: KeyCode::PageUp,
                ..
            } => self.page_up(),
            KeyEvent {
                code: KeyCode::PageDown,
                ..
            } => self.page_down(),
            _ => {}
        }
    }

    fn insert_char(&mut self, c: char) {
        let line = &mut self.lines[self.cursor_row];
        line.insert(self.cursor_byte, c);
        self.cursor_byte += c.len_utf8();
        self.prefer_col = self.cursor_display_col();
    }

    fn newline(&mut self) {
        let line = &mut self.lines[self.cursor_row];
        let rest = line[self.cursor_byte..].to_string();
        line.truncate(self.cursor_byte);
        self.cursor_row += 1;
        self.cursor_byte = 0;
        self.lines.insert(self.cursor_row, rest);
        self.prefer_col = 0;
    }

    fn delete_backward(&mut self) {
        if self.cursor_byte > 0 {
            // Delete character before cursor
            let line = &mut self.lines[self.cursor_row];
            let prev_byte = prev_char_boundary(line, self.cursor_byte);
            line.drain(prev_byte..self.cursor_byte);
            self.cursor_byte = prev_byte;
        } else if self.cursor_row > 0 {
            // Join with previous line
            let line = self.lines.remove(self.cursor_row);
            self.cursor_row -= 1;
            self.cursor_byte = self.lines[self.cursor_row].len();
            self.lines[self.cursor_row].push_str(&line);
        }
        self.prefer_col = self.cursor_display_col();
    }

    fn delete_forward(&mut self) {
        let line = &self.lines[self.cursor_row];
        if self.cursor_byte < line.len() {
            let next_byte = next_char_boundary(line, self.cursor_byte);
            let line = &mut self.lines[self.cursor_row];
            line.drain(self.cursor_byte..next_byte);
        } else if self.cursor_row + 1 < self.lines.len() {
            // Join with next line
            let next_line = self.lines.remove(self.cursor_row + 1);
            self.lines[self.cursor_row].push_str(&next_line);
        }
    }

    fn move_left(&mut self) {
        if self.cursor_byte > 0 {
            let line = &self.lines[self.cursor_row];
            self.cursor_byte = prev_char_boundary(line, self.cursor_byte);
        } else if self.cursor_row > 0 {
            self.cursor_row -= 1;
            self.cursor_byte = self.lines[self.cursor_row].len();
        }
        self.prefer_col = self.cursor_display_col();
    }

    fn move_right(&mut self) {
        let line = &self.lines[self.cursor_row];
        if self.cursor_byte < line.len() {
            self.cursor_byte = next_char_boundary(line, self.cursor_byte);
        } else if self.cursor_row + 1 < self.lines.len() {
            self.cursor_row += 1;
            self.cursor_byte = 0;
        }
        self.prefer_col = self.cursor_display_col();
    }

    fn move_up(&mut self) {
        if self.cursor_row > 0 {
            self.cursor_row -= 1;
            self.cursor_byte =
                display_col_to_byte(&self.lines[self.cursor_row], self.prefer_col);
        }
    }

    fn move_down(&mut self) {
        if self.cursor_row + 1 < self.lines.len() {
            self.cursor_row += 1;
            self.cursor_byte =
                display_col_to_byte(&self.lines[self.cursor_row], self.prefer_col);
        }
    }

    fn move_home(&mut self) {
        self.cursor_byte = 0;
        self.prefer_col = 0;
    }

    fn move_end(&mut self) {
        self.cursor_byte = self.lines[self.cursor_row].len();
        self.prefer_col = self.cursor_display_col();
    }

    fn page_up(&mut self) {
        self.cursor_row = 0;
        self.cursor_byte =
            display_col_to_byte(&self.lines[self.cursor_row], self.prefer_col);
    }

    fn page_down(&mut self) {
        self.cursor_row = self.lines.len().saturating_sub(1);
        self.cursor_byte =
            display_col_to_byte(&self.lines[self.cursor_row], self.prefer_col);
    }

    pub fn cursor_display_col(&self) -> usize {
        let line = &self.lines[self.cursor_row];
        byte_to_display_col(line, self.cursor_byte)
    }

    pub fn update_scroll(&mut self, max_width: usize, visible_height: u16) {
        let visual_row = visual_cursor_row(self, max_width);
        let vh = visible_height as usize;
        if visual_row < self.scroll {
            self.scroll = visual_row;
        } else if visual_row >= self.scroll + vh {
            self.scroll = visual_row.saturating_sub(vh.saturating_sub(1));
        }
    }
}

/// Compute the visual (wrapped) row of the cursor.
fn visual_cursor_row(editor: &Editor, max_width: usize) -> usize {
    let mut visual_row = 0usize;
    for (li, logical_line) in editor.lines.iter().enumerate() {
        let wrapped_count = wrap_count(logical_line, max_width);
        if li < editor.cursor_row {
            visual_row += wrapped_count;
        } else {
            let line_up_to_cursor = &logical_line[..editor.cursor_byte];
            let cursor_display_col = UnicodeWidthStr::width(line_up_to_cursor);
            if max_width > 0 {
                visual_row += cursor_display_col / max_width;
            }
            break;
        }
    }
    visual_row
}

fn prev_char_boundary(s: &str, byte: usize) -> usize {
    if byte == 0 {
        return 0;
    }
    let mut prev = 0;
    for (i, _) in s.char_indices() {
        if i >= byte {
            break;
        }
        prev = i;
    }
    prev
}

fn next_char_boundary(s: &str, byte: usize) -> usize {
    if byte >= s.len() {
        return s.len();
    }
    for (i, c) in s.char_indices() {
        if i >= byte {
            return i + c.len_utf8();
        }
    }
    s.len()
}

pub fn byte_to_display_col(s: &str, byte: usize) -> usize {
    let slice = if byte <= s.len() { &s[..byte] } else { s };
    UnicodeWidthStr::width(slice)
}

pub fn display_col_to_byte(s: &str, target_col: usize) -> usize {
    let mut col = 0usize;
    for (i, c) in s.char_indices() {
        let cw = UnicodeWidthChar::width(c).unwrap_or(1);
        if col + cw > target_col {
            return i;
        }
        col += cw;
    }
    s.len()
}

fn wrap_count(s: &str, max_width: usize) -> usize {
    if max_width == 0 || s.is_empty() {
        return 1;
    }
    let mut lines = 1usize;
    let mut col = 0usize;
    for c in s.chars() {
        let cw = UnicodeWidthChar::width(c).unwrap_or(1);
        if col + cw > max_width {
            lines += 1;
            col = cw;
        } else {
            col += cw;
        }
    }
    lines
}

/// Wrap a plain text string into display lines that fit within `max_width`.
pub fn wrap_plain_text(text: &str, max_width: usize) -> Vec<String> {
    if max_width == 0 || text.is_empty() {
        return vec![text.to_string()];
    }
    let mut result: Vec<String> = Vec::new();
    let mut chunk = String::new();
    let mut chunk_w = 0usize;
    for ch in text.chars() {
        let ch_w = UnicodeWidthChar::width(ch).unwrap_or(1);
        if chunk_w + ch_w > max_width {
            result.push(std::mem::take(&mut chunk));
            chunk_w = 0;
        }
        chunk.push(ch);
        chunk_w += ch_w;
    }
    if !chunk.is_empty() {
        result.push(chunk);
    }
    if result.is_empty() {
        result.push(String::new());
    }
    result
}
