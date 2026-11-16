tokenize_vala :: (using buffer: *Buffer, start_offset := -1, count := -1) -> [] Buffer_Region {
    tokenizer := get_tokenizer(buffer);
    if start_offset >= 0 {
        start := clamp(start_offset, 0, bytes.count);
        length := bytes.count - start;
        if count >= 0 then length = min(length, count);
        tokenizer.t = bytes.data + start;
        tokenizer.max_t = tokenizer.t + length;
    }
    previous: Token;

    while true {
        token := get_next_token(*tokenizer);
        if token.type == .eof break;

        if token.type == .punctuation && token.punctuation == .l_paren && previous.type == .identifier {
            memset(tokens.data + previous.start, xx Token_Type.function, previous.len);
        }
        highlight_token(buffer, token);
        if token.type != .comment && token.type != .multiline_comment then previous = token;
    }
    return .[];
}

get_next_vala_token :: get_next_token;

#scope_file

get_next_token :: (using tokenizer: *Tokenizer) -> Token {
    eat_white_space(tokenizer);
    token: Token;
    token.start = xx (t - buf.data);
    if t >= max_t { token.type = .eof; return token; }

    char := t.*;
    if ascii_is_alpha(char) || char == #char "_" || is_utf32_letter(character_utf8_to_utf32(t, max_t - t)) {
        token.type = .identifier;
        identifier := read_utf8_identifier_string(tokenizer);
        found, kind := table_find(*KEYWORD_MAP, identifier);
        if found then token.type = kind;
    } else if ascii_is_digit(char) || (char == #char "." && t + 1 < max_t && ascii_is_digit((t + 1).*)) {
        token.type = .number;
        parse_number(tokenizer);
    } else if char == {
        case #char "@";
            t += 1;
            if t < max_t && t.* == #char "\"" {
                token.type = .string_literal;
                parse_quoted(tokenizer, true);
            } else {
                // @ escapes keywords, e.g. @class is an identifier.
                identifier := read_utf8_identifier_string(tokenizer);
                token.type = ifx identifier.count then .identifier else .invalid;
            }
        case #char "\"";
            token.type = ifx at_string(tokenizer, "\"\"\"") then .multiline_string else .string_literal;
            parse_quoted(tokenizer);
        case #char "'";
            token.type = .char_literal;
            parse_quoted(tokenizer);
        case #char "/";
            token.type = parse_slash(tokenizer);
        case #char "#";
            token.type = .directive;
            t += 1;
            eat_white_space(tokenizer, true);
            read_utf8_identifier_string(tokenizer);
        case #char "("; token.type = .punctuation; token.punctuation = .l_paren;   t += 1;
        case #char ")"; token.type = .punctuation; token.punctuation = .r_paren;   t += 1;
        case #char "["; token.type = .punctuation; token.punctuation = .l_bracket; t += 1;
        case #char "]"; token.type = .punctuation; token.punctuation = .r_bracket; t += 1;
        case #char "{"; token.type = .punctuation; token.punctuation = .l_brace;   t += 1;
        case #char "}"; token.type = .punctuation; token.punctuation = .r_brace;   t += 1;
        case #char ";"; #through;
        case #char ","; #through;
        case #char ".";
            token.type = .punctuation;
            t += 1;
        case;
            token.type = ifx array_find(cast([] u8) "=+-*<>!&|%^~?:", char) then .operation else .invalid;
            t += 1;
    }
    token.len = xx (t - buf.data - token.start);
    return token;
}

parse_number :: (using tokenizer: *Tokenizer) {
    if at_string(tokenizer, "0x") || at_string(tokenizer, "0X") {
        t += 2;
        while t < max_t && is_hex(t.*) t += 1;
    } else if at_string(tokenizer, "0b") || at_string(tokenizer, "0B") {
        t += 2;
        while t < max_t && (t.* == #char "0" || t.* == #char "1") t += 1;
    } else {
        while t < max_t && ascii_is_digit(t.*) t += 1;
        if t < max_t && t.* == #char "." {
            t += 1;
            while t < max_t && ascii_is_digit(t.*) t += 1;
        }
        if t < max_t && (t.* == #char "e" || t.* == #char "E") {
            t += 1;
            if t < max_t && (t.* == #char "+" || t.* == #char "-") t += 1;
            while t < max_t && ascii_is_digit(t.*) t += 1;
        }
    }
    while t < max_t && array_find(cast([] u8) "uUlLfFdD", t.*) t += 1;
}

parse_slash :: (using tokenizer: *Tokenizer) -> Token_Type {
    t += 1;
    if t >= max_t return .operation;
    if t.* == #char "/" {
        eat_until_newline(tokenizer);
        return .comment;
    }
    if t.* == #char "*" {
        t += 1;
        while t < max_t {
            if at_string(tokenizer, "*/") { t += 2; break; }
            t += 1;
        }
        return .multiline_comment;
    }
    if t.* == #char "=" then t += 1;
    return .operation;
}

// Keep a template together, including quoted strings and parentheses inside
// $(expressions), so their delimiters cannot affect indentation or pair matching.
parse_quoted :: (using tokenizer: *Tokenizer, template := false, depth := 0) {
    if depth >= 64 { t = max_t; return; } // bound nesting in incomplete/malformed input
    quote := t.*;
    verbatim := quote == #char "\"" && at_string(tokenizer, "\"\"\"");
    t += ifx verbatim then 3 else 1;
    while t < max_t {
        if verbatim {
            if at_string(tokenizer, "\"\"\"") { t += 3; return; }
        } else {
            if t.* == quote { t += 1; return; }
            if t.* == #char "\n" || t.* == #char "\r" return;
            if t.* == #char "\\" {
                t += 1;
                if t < max_t && t.* != #char "\n" && t.* != #char "\r" then t += 1;
                continue;
            }
        }
        if template && at_string(tokenizer, "$(") {
            t += 2;
            parens := 1;
            while t < max_t && parens > 0 {
                if t.* == #char "\"" || t.* == #char "'" {
                    parse_quoted(tokenizer, false, depth + 1);
                } else if at_string(tokenizer, "@\"") {
                    t += 1;
                    parse_quoted(tokenizer, true, depth + 1);
                } else if t.* == #char "/" {
                    parse_slash(tokenizer);
                } else {
                    if t.* == #char "(" then parens += 1;
                    if t.* == #char ")" then parens -= 1;
                    t += 1;
                }
            }
        } else {
            t += 1;
        }
    }
}

Token :: struct {
    using #as base: Base_Token;
    punctuation: enum { other; l_paren; r_paren; l_bracket; r_bracket; l_brace; r_brace; };
}

// Vala reference: https://docs.vala.dev/tutorials/main/02-00-basics/02-02-syntax-overview.html
KEYWORDS :: string.[
    "as", "base", "break", "case", "catch", "class", "construct", "continue", "default", "delegate",
    "delete", "do", "else", "ensures", "enum", "errordomain", "finally", "for", "foreach", "get", "if",
    "in", "interface", "is", "lock", "namespace", "new", "requires", "return", "set", "signal", "sizeof",
    "struct", "switch", "this", "throw", "throws", "try", "typeof", "unlock", "using", "var", "while",
    "with", "yield",
];
TYPE_KEYWORDS :: string.[
    "bool", "char", "uchar", "unichar", "short", "ushort", "int", "uint", "long", "ulong",
    "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "size_t", "ssize_t",
    "float", "double", "string", "void",
];
VALUE_KEYWORDS :: string.["true", "false", "null"];
MODIFIER_KEYWORDS :: string.[
    "abstract", "async", "const", "dynamic", "extern", "inline", "internal", "out", "override", "owned",
    "params", "private", "protected", "public", "ref", "sealed", "static", "unowned", "virtual", "weak",
];
KEYWORD_MAP :: #run -> Table(string, Token_Type) {
    table: Table(string, Token_Type);
    table_resize(*table, 10 * (KEYWORDS.count + TYPE_KEYWORDS.count + VALUE_KEYWORDS.count + MODIFIER_KEYWORDS.count));
    for KEYWORDS          table_add(*table, it, .keyword);
    for TYPE_KEYWORDS     table_add(*table, it, .type);
    for VALUE_KEYWORDS    table_add(*table, it, .value);
    for MODIFIER_KEYWORDS table_add(*table, it, .modifier);
    return table;
}
