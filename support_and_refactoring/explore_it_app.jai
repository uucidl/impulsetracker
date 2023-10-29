/*

2023-10-14, Nicolas Léveillé.

A porting effort of impulse tracker from TASM to say C, involves relinquishing control. Assembly allows a lot more precision in where data is being stored, how parameters are being passed from functions to functions. C on the other hand does not dictate the precise sequence in which data is stored, and uses an unspecified calling convention by default, and certainly not full flexibility in how parameters are passed from functions to functions.

Additionally, Impulse Tracker is written in real mode 16-bit assembly, without the unified unique address space that C is made for.

If we want to iteratively port Impulse Tracker from TASM to C, we need to be able to have C and TASM cooperate. This will require agreeing on two things:

1. datastructures, which will involve defining them both in C and ASM, since there's no way for those languages to natively share datatypes.

2. names of symbols, so that we can find each other

3. calling conventions. From C to ASM maybe we'll have to generate little trampoline functions that convert from the C calling convention to the actual assembly code. From ASM to C we'll have to just encode the calling convention in use by the real mode C compiler we'll use at that moment.

The code base is already organized so that symbols are prefixed with a namespace that indicate from which object file they're from. 

Every .ASM file corresponds to a .OBJ file.
In an .ASM file we see a bunch of 'Extrn' symbols, which are imported from other .OBJ. We also see a bunch of 'Global', 'Public' symbols which are exported to other .OBJ

Q. Are symbols case sensitive?

Some interesting strings
------------------------

These appear to indicate data that needs to be in a defined ordering. They indicate missing 'structs'
- '* ORDER IS IMPORTANT'
- 'Order important!'

MSDOS and BIOS "Syscalls" which need to be emulated:
- 'Int     ' 21h 10h and so on

Oddities
--------

Nested Proc / EndP exist, such as D_InitLoadModule -> D_InitLoadModule2

Other similar efforts
---------------------
The guy who wrote protracker-clone and ft2-clone has a version of the replay code ported to C already.

*/

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";

global_root_dir: string;
global_symbol_assignments: [..]Symbol_Assignment;
global_file_includes: [..]File_Includes;

Symbol_Assignment :: struct {
    file: string; 
    symbol: string;
    value: string;
}

File_Includes :: struct {
    file: string;
    included_file: string;
    exists: bool;
}

impulse_tracker_path :: (relative: string) -> string {
    return join(global_root_dir, relative, separator="/");
}

main :: () {
    global_root_dir = join("H:", "impulsetracker", separator="/");

    files := string.[
        "DEBUG.INC",
        "IT.ASM",
        "IT_DISK.ASM",
        "IT_DISPL.ASM",
        "IT_D_INF.INC",
        "IT_D_RI.INC",
        "IT_D_RM.INC",
        "IT_D_WM.INC",
        "IT_EMS.ASM",
        "IT_ERR.ASM",
        "IT_F.ASM",
        "IT_FOUR.ASM",
        "IT_G.ASM",
        "IT_H.ASM",
        "IT_I.ASM",
        "IT_K.ASM",
        "IT_L.ASM",
        "IT_M.ASM",
        "IT_MDATA.ASM",
        "IT_MMTSR.ASM",
        "IT_MOUSE.ASM",
        "IT_MSG.ASM",
        "IT_MUSIC.ASM",
        "IT_M_EFF.INC",
        "IT_NET.ASM",
        "IT_OBJ1.ASM",
        "IT_PE.ASM",
        "IT_PE_V.INC",
        "IT_S.ASM",
        "IT_TIMER.INC",
        "IT_TUTE.ASM",
        "IT_VESA.ASM",
        "NETWORK.INC",
        "PE_TRANS.INC",
        "SWITCH.INC",
        "USERNAME.INC",
        "WAVSWITC.INC",
    ];


    for files {
        load_tasm_file(impulse_tracker_path(it));
    }

    print("Assignments:\n");
    print("File,Symbol,Value\n");
    for global_symbol_assignments {
        print("'%','%',%\n", it.file, it.symbol, it.value);
    }

    print("Includes:\n");
    print("File,IncludedFile,Exists\n");
    for global_file_includes {
        print("'%','%',%\n", it.file, it.included_file, ifx it.exists "1" else "0");
    }
}

load_tasm_file :: (path: string) {
    content := read_entire_file(path, zero_terminated = true);
    content.count += 1; // include the zero terminator

    parser: *Tasm_Parser = New(Tasm_Parser);

    Data_Collector :: struct {
        base: Tasm_Callbacks;

        file: string;
    };

    init_tasm_parser(parser, content, *Data_Collector.{
        file = path,

        base.on_include = (self_: *Tasm_Callbacks, filename: string, parser: Tasm_Parser) {
            self := cast(*Data_Collector) self_;

            path := impulse_tracker_path(filename);

            exists := file_exists(path);
            if !exists {
                log("Warning, file % included by % does not appear to exist", filename, self.file);                
            }

            to_upper_in_place(filename);
            array_add(*global_file_includes, .{self.file, filename, exists});
    
            // Is there a way to check whether that path corresponds to
            // the path of another file that I already am parsing?
            //
            // The easiest is to simply uppercase everything, I guess,
            // knowing that I'm running on Windows and these were DOS
            // files anyway.
        },

        base.on_symbol_assignment = (self_: *Tasm_Callbacks, name: string, op: string, value: string, left: string, right: string, parser: Tasm_Parser) {
            self := cast(*Data_Collector) self_;
            // It's interesting to list all symbols which are assigned, especially when they come from an include .INC file, as they may control important program behavior.
            array_add(*global_symbol_assignments, .{self.file, name, value});
        },
    }.base);
    
    parse_tasm(parser);
}
    
Tasm_Callbacks :: struct {
    using base: Tasm_Lexer_Callbacks;

    on_include := (self: *Tasm_Callbacks, filename: string, parser: Tasm_Parser) {};
    on_symbol_assignment := (self: *Tasm_Callbacks, name: string, op: string, value: string, left: string, right: string, parser: Tasm_Parser) {};
}

Tasm_Parser :: struct {
    content: string;
    pos: s64;
    callbacks: *Tasm_Callbacks;

    token: Tasm_Token;
    token_callbacks: Token_Production_Lexer_Callbacks;

    lexer_callbacks: Composed_Lexer_Callbacks;
}

Tasm_Token_Kind :: enum {
    None;
    Error;
    Eof;
    Newline;
    Symbol;
    Number;
    Operator;
}

Tasm_Token :: struct {
    kind: Tasm_Token_Kind;
    pos: s64;
    len: s64;
}
 
Tasm_Lexer_Callbacks :: struct {
    on_lexer_whitespace := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {};
    on_lexer_comment := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {};
    on_lexer_newline := (self: *Tasm_Lexer_Callbacks, start: s64, parser: Tasm_Parser) {};
    on_lexer_operator := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {};
    on_lexer_number := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {};
    on_lexer_symbol := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {};
    on_lexer_error_unexpected_character := (self: *Tasm_Lexer_Callbacks, pos: s64, parser: Tasm_Parser) {};
}

Token_Production_Lexer_Callbacks :: struct {
    using base: Tasm_Lexer_Callbacks;
    dest: *Tasm_Parser;
}

Composed_Lexer_Callbacks :: struct {
    using base: Tasm_Lexer_Callbacks;
    a: *Tasm_Lexer_Callbacks;
    b: *Tasm_Lexer_Callbacks;

    on_lexer_whitespace = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_whitespace(self.a, start_pos, end_pos, parser);
        self.b.on_lexer_whitespace(self.b, start_pos, end_pos, parser);
    };
    on_lexer_comment = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_comment(self.a, start_pos, end_pos, parser);
        self.b.on_lexer_comment(self.b, start_pos, end_pos, parser);
    };
    on_lexer_newline = (self_: *Tasm_Lexer_Callbacks, pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_newline(self.a, pos, parser);
        self.b.on_lexer_newline(self.b, pos, parser);
    };
    on_lexer_operator = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_operator(self.a, start_pos, end_pos, parser);
        self.b.on_lexer_operator(self.b, start_pos, end_pos, parser);
    };
    on_lexer_number = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_number(self.a, start_pos, end_pos, parser);
        self.b.on_lexer_number(self.b, start_pos, end_pos, parser);
    };
    on_lexer_symbol = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_symbol(self.a, start_pos, end_pos, parser);
        self.b.on_lexer_symbol(self.b, start_pos, end_pos, parser);
    };
    on_lexer_error_unexpected_character = (self_: *Tasm_Lexer_Callbacks, pos: s64, parser: Tasm_Parser) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_error_unexpected_character(self.a, pos, parser);
        self.b.on_lexer_error_unexpected_character(self.b, pos, parser);
    };
}

init_tasm_parser :: (parser: *Tasm_Parser, content: string, callbacks: *Tasm_Callbacks) {
    parser.content = content;
    parser.callbacks = callbacks;
    parser.token_callbacks = Token_Production_Lexer_Callbacks.{
        on_lexer_whitespace = (self_: *Tasm_Lexer_Callbacks, f: s64, l: s64, parser: Tasm_Parser) { 
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .None };
        },
        on_lexer_newline = (self_: *Tasm_Lexer_Callbacks, pos: s64, parser: Tasm_Parser) {
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Newline, pos = pos, len = 1 };
        },
        on_lexer_comment = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, parser: Tasm_Parser) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .None };
        },
        on_lexer_operator = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, parser: Tasm_Parser) { 
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .Operator, pos = f, len = l - f }; 
        },
        on_lexer_number = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, parser: Tasm_Parser) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .Number, pos = f, len = l - f }; 
        },
        on_lexer_symbol = (self_: *Tasm_Lexer_Callbacks, f: s64, l: s64, parser: Tasm_Parser) { 
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Symbol, pos = f, len = l - f }; 
        },
        on_lexer_error_unexpected_character = (self_: *Tasm_Lexer_Callbacks, pos: s64, parser: Tasm_Parser) {
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Error, pos = pos };
        },
        dest = parser,
    };
    parser.token_callbacks.dest = parser;
    parser.lexer_callbacks = Composed_Lexer_Callbacks.{ 
        a = *parser.token_callbacks.base,
        b = *parser.callbacks.base,
    };
}

Parser_Mark :: struct {
    token: Tasm_Token;
    pos: s64;
}

parser_mark :: (parser: Tasm_Parser) -> Parser_Mark {
    return Parser_Mark.{ token = parser.token, pos = parser.pos };
}

parser_rollback :: (parser: *Tasm_Parser, mark: Parser_Mark) {
    parser.token = mark.token;
    parser.pos = mark.pos;
}

parse_tasm :: (parser: *Tasm_Parser) {
    p := *parser.content[parser.pos];
    if !next_token(parser) {
        return;
    }    
    while true {
        mark := parser_mark(parser);
        if parse_symbol_assignment(parser) {
        } else if parse_include(parser) {
        } else {
            // rollback and synchronize to the next newline
            parser_rollback(parser, mark);
            while parser.token.kind != .Newline {
                found := next_token(parser);
                if !found {
                    return;
                }
            }
            next_token(parser);
        }
    }
}

parse_include :: (parser: *Tasm_Parser) -> success: bool {
    using parser;

    mark := parser_mark(parser);

    if token.kind != .Symbol {
        return false;
    }
    symbol := to_string(*parser.content[token.pos], token.len);
    if symbol != "include" {
        return false;
    }
    
    next_token(parser);
    if token.kind != .Symbol {
        parser_rollback(parser, mark);
        return false;
    }
    filename := to_string(*parser.content[token.pos], token.len);

    next_token(parser);
    if token.kind != .Newline {
        parser_rollback(parser, mark);
        return false;
    }

    parser.callbacks.on_include(parser.callbacks, filename, parser);

    return true;
}

parse_symbol_assignment :: (parser: *Tasm_Parser) -> success: bool {
    // whitespace
    // <user-symbol>
    // 'EQU' or '='
    // <expression>
    // comment
    
    // => will call parser.callbacks.on_symbol_assignment

    using parser;

    mark := parser_mark(parser);

    if token.kind != .Symbol {
        return false;
    }
    symbol := to_string(*parser.content[token.pos], token.len);
    
    next_token(parser);

    op: string;
    if token.kind == .Symbol {
        op = to_string(*parser.content[token.pos], token.len);
        if op != "EQU" {
            parser_rollback(parser, mark);
            return false;
        }
    } else if token.kind == .Operator {
        op = to_string(*parser.content[token.pos], token.len);
        if op != "=" {
            parser_rollback(parser, mark);
            return false;
        }
    } else {
        parser_rollback(parser, mark);
        return false;
    }
    
    next_token(parser);
    if token.kind != .Number {
        parser_rollback(parser, mark);
        return false;
    }
    number := to_string(*parser.content[token.pos], token.len);
    
    start := pos;
    next_token(parser);
    if token.kind != .Newline {  
        parser_rollback(parser, mark);
        return false; // error, garbage until the end of the line
    }

    parser.callbacks.on_symbol_assignment(parser.callbacks, symbol, op, number, "", "", parser);
    return true;
}

next_token :: (parser: *Tasm_Parser) -> found: bool {
    while true {
        if !tasm_lexer_next(parser, *parser.lexer_callbacks.base) { 
            parser.token.kind = .Eof;
            parser.token.pos = parser.pos;
            parser.token.len = 0;
            return false;
        }
        if parser.token.kind != .None {
            return true;
        }
    }
    return true;
}

tasm_lexer_next :: (parser: *Tasm_Parser, callbacks: *Tasm_Lexer_Callbacks) -> found: bool {
    c := parser.content[parser.pos];
    if c == {
        case #char "\0"; return false;

        case #char " "; #through;
        case #char "\t";
            start := parser.pos;
            parser.pos += 1;
            
            is_whitespace :: (c: u8) -> bool {
                return c == #char " " || c == #char "\t";
            }

            while true {
                c := parser.content[parser.pos];
                if !is_whitespace(c) {
                    break;
                }
                parser.pos += 1;
            }
            callbacks.on_lexer_whitespace(callbacks, start, parser.pos, parser);

        case #char "\r";
            start := parser.pos;
            parser.pos += 1;
            c := parser.content[parser.pos];
            if c == #char "\n" {
                callbacks.on_lexer_newline(callbacks, parser.pos, parser);
            } else {
                callbacks.on_lexer_whitespace(callbacks, start, parser.pos, parser);
            }

        case #char "\n"; {
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_newline(callbacks, start, parser);
        }

        case #char ";"; // A line comment is starting here.
            start := parser.pos;
            parser.pos += 1;
            end := parser.pos;
            while true {             
                c := parser.content[parser.pos];
                if c == {
                    case #char "\0"; #through;
                    case #char "\n"; 
                        end = parser.pos; break;

                    case; parser.pos += 1;
                }
            }
            callbacks.on_lexer_comment(callbacks, start, end, parser);

        case #char "0"; #through;
        case #char "1"; #through;
        case #char "2"; #through;
        case #char "3"; #through;
        case #char "4"; #through;
        case #char "5"; #through;
        case #char "6"; #through;
        case #char "7"; #through;
        case #char "8"; #through;
        case #char "9";
            start := parser.pos;
            parser.pos += 1;
            is_numeric_character :: (c: u8) -> bool {
                return (#char "0" <= c && c <= #char "9");
            }
            while true {
                c := parser.content[parser.pos];
                if !is_numeric_character(c) {
                    break;
                }
                parser.pos += 1;
            }
            
            if parser.content[parser.pos] == #char "h" {
                // hex number
                parser.pos += 1;
            }
            is_numeric_boundary :: (c: u8) -> bool {
                return c == #char " " || c == #char "\r" || c == #char "\t" || c == #char "\n" || c == #char "\0";
            }
            if !is_numeric_boundary (parser.content[parser.pos]) {
                callbacks.on_lexer_error_unexpected_character(callbacks, parser.pos, parser);
            } else {            
                callbacks.on_lexer_number(callbacks, start, parser.pos, parser);
            }

        case #char "=";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_operator(callbacks, start, parser.pos, parser);

        case;
            is_keyword_character :: (c: u8) -> bool {
                return (#char "A" <= c && c <= #char "Z") || (#char "a" <= c && c <= #char "z") || (#char "0" <= c && c <= #char "9") || c == #char "_" || c == #char ".";
            };

            if is_keyword_character(c) {
                start := parser.pos;
                parser.pos += 1;
                while true {
                    c := parser.content[parser.pos];
                    if !is_keyword_character(c) {
                        break;
                    }
                    parser.pos += 1;
                }
                callbacks.on_lexer_symbol(callbacks, start, parser.pos, parser);                    
            } else {
                callbacks.on_lexer_error_unexpected_character(callbacks, parser.pos, parser);
                parser.pos += 1;
            }
    }

    return true;
}

