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

// @todo: logic to fetch comments after a parsable structure should consider fetching continuation lines of the form:
// ```
// symbol = value ; documentation
//                ; continued on the next line
// ```

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";

global_root_dir: string;
global_symbol_assignments: [..]Symbol_Assignment;
global_file_includes: [..]File_Includes;
global_proc_decls: [..]Proc_Decls;

Symbol_Assignment :: struct {
    file: string; 
    symbol: string;
    value: string;
    documentation: string;
}

File_Includes :: struct {
    file: string;
    included_file: string;
}

Proc_Decls :: struct {
    file: string;
    proc_name: string;
    proc_distance: string;
    num_lines: s64;
}

main :: () {
    global_root_dir = join("H:", "impulsetracker", separator="/");

    set_working_directory(global_root_dir);

    load_tasm_file("IT_K.ASM");

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
        load_tasm_file(it);
    }

    print("Assignments:\n");
    print("File,Symbol,Value,Documentation\n");
    for global_symbol_assignments {
        print("'%','%',%, '%'\n", it.file, it.symbol, it.value, it.documentation);
    }

    print("Includes:\n");
    print("File,IncludedFile\n");
    for global_file_includes {
        print("'%','%'\n", it.file, it.included_file);
    }

    print("Procedure Declarations:\n");
    print("File,ProcName,ProcDistance,NumLines\n");
    for global_proc_decls {
        print("'%','%','%', %\n", it.file, it.proc_name, it.proc_distance, it.num_lines);
    }
}

load_tasm_file :: (path: string) {
    content := read_entire_file(path, zero_terminated = true);
    content.count += 1; // include the zero terminator

    Data_Collector :: struct {
        base: Tasm_Callbacks(Data_Collector);

        file: string;
    };

    parser := New(Tasm_Parser(Data_Collector));

    init_tasm_parser(parser, content, *Data_Collector.{
        file = path,

        base.on_error = (self: *Data_Collector, msg: string, state: Tasm_Parser_State) {
            log("Error, file % encountered an error in context '%' at position %'", self.file, msg, state.pos);

            pos := state.token.pos;
            reverse_pos := pos;
            while reverse_pos > 1 && state.content[reverse_pos - 1] != #char "\n" {
                reverse_pos -= 1;
            }
            beginning_of_line := reverse_pos - 1;

            end_of_line := pos + state.token.len;
            while state.content[end_of_line] != #char "\0" && state.content[end_of_line] != #char "\r" && state.content[end_of_line] != #char "\n" {
                end_of_line += 1;
            }
            end_of_good_range := state.token.pos;
            log("Context: %*%", to_string(*state.content[beginning_of_line], end_of_good_range - beginning_of_line), to_string(*state.content[end_of_good_range], end_of_line - end_of_good_range));
        },
        
        base.on_include = (self: *Data_Collector, filename: string, state: Tasm_Parser_State) {
            path := filename;

            exists := file_exists(path);
            if !exists {
                log("Warning, file % included by % does not appear to exist", filename, self.file);                
            }

            to_upper_in_place(filename);
            array_add(*global_file_includes, .{self.file, filename});
    
            // Is there a way to check whether that path corresponds to
            // the path of another file that I already am parsing?
            //
            // The easiest is to simply uppercase everything, I guess,
            // knowing that I'm running on Windows and these were DOS
            // files anyway.
        },

        base.on_symbol_assignment = (self: *Data_Collector, name: string, op: string, value: string, left: string, right: string, state: Tasm_Parser_State) {
            // It's interesting to list all symbols which are assigned, especially when they come from an include .INC file, as they may control important program behavior.
            array_add(*global_symbol_assignments, .{self.file, name, value, right});
        },

        base.on_procedure_decl = (self: *Data_Collector, name: string, distance: string, state: Tasm_Parser_State) {
            array_add(*global_proc_decls, .{self.file, name, distance, 0});
        },
        
        base.on_procedure_decl_end = (self: *Data_Collector, name: string, num_lines: s64, state: Tasm_Parser_State) {
            ri := global_proc_decls.count;
            while ri > 0 {
                proc_decl := *global_proc_decls[ri - 1];
                if proc_decl.proc_name == name {
                    assert(proc_decl.num_lines == 0);
                    proc_decl.num_lines = num_lines;
                    return;
                }
                ri -= 1;
            }
            assert(false); // couldn't find a procedure by that name!
        },

/*
// Debug
        base.on_lexer_error_unexpected_character = (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
            log("error_unexpected_character: %: %", pos, to_string(*state.content[pos], 1));
        },
        base.on_lexer_whitespace = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_whitespace: % %", start_pos, end_pos);
        },
        base.on_lexer_string = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_string: % %", start_pos, end_pos);
        },
        base.on_lexer_comment = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_comment: % %", start_pos, end_pos);
        },
        base.on_lexer_newline = (self: *Tasm_Lexer_Callbacks, start: s64, state: Tasm_Parser_State) {
            log("lexer_newline: %", start);
        },
        base.on_lexer_operator = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_operator: % %", start_pos, end_pos);
        },
        base.on_lexer_paren_open = (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
            log("lexer_paren_open %", pos);
        },
        base.on_lexer_paren_close = (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State)  {
            log("lexer_paren_close %", pos);
        },
        base.on_lexer_bracket_open = (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State)  {
            log("lexer_bracket_open %", pos);
        },
        base.on_lexer_bracket_close = (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State)  {
            log("lexer_bracket_close %", pos);
        },
        base.on_lexer_number = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_number: % %", start_pos, end_pos);
        },
        base.on_lexer_symbol = (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            log("lexer_symbol: % %: %", start_pos, end_pos, to_string(*state.content[start_pos], end_pos - start_pos));
        },
*/
    });
    
    parse_tasm(parser);
}
    
Tasm_Callbacks :: struct (T: Type) {
    using base: Tasm_Lexer_Callbacks;   
    
    on_error := (self: *T, msg: string, state: Tasm_Parser_State) {};
    on_include := (self: *T, filename: string, state: Tasm_Parser_State) {};
    on_symbol_assignment := (self: *T, name: string, op: string, value: string, left: string, right: string, state: Tasm_Parser_State) {};
    on_procedure_decl := (self: *T, name: string, distance: string, state: Tasm_Parser_State) {};
    on_procedure_decl_end := (self: *T, name: string, num_lines: s64, state: Tasm_Parser_State) {};
}

Tasm_Parser_State :: struct {
    content: string;
    pos: s64;
    token: Tasm_Token;
}

Tasm_Parser :: struct (T: Type) {
    using base : Tasm_Parser_State;
    
    // All must be filled by the user:
    callbacks: Tasm_Callbacks(T);
    callbacks_data: *T;

    token_callbacks: Token_Production_Lexer_Callbacks;
    lexer_callbacks: Composed_Lexer_Callbacks;
}

Tasm_Token_Kind :: enum {
    None;
    Error;
    Eof;
    Newline;
    Symbol;
    String;
    Number;
    Operator;
    ParenOpen;
    ParenClose;
    BracketOpen;
    BracketClose;
}

Tasm_Token :: struct {
    kind: Tasm_Token_Kind;
    pos: s64;
    len: s64;
}
 
Tasm_Lexer_Callbacks :: struct {
    on_lexer_error_unexpected_character := (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {};

    on_lexer_whitespace := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {};
    on_lexer_string := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {};
    on_lexer_comment := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {};
    on_lexer_newline := (self: *Tasm_Lexer_Callbacks, start: s64, state: Tasm_Parser_State) {};
    on_lexer_operator := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {}
    ;
    on_lexer_paren_open := (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {}
    on_lexer_paren_close := (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {}
    on_lexer_bracket_open := (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {}
    on_lexer_bracket_close := (self: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {}
    on_lexer_number := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {};
    on_lexer_symbol := (self: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {};
}

Token_Production_Lexer_Callbacks :: struct {
    using base: Tasm_Lexer_Callbacks;
    dest: *Tasm_Parser_State;
}

Composed_Lexer_Callbacks :: struct {
    using base: Tasm_Lexer_Callbacks;
    a: *Tasm_Lexer_Callbacks;
    b: *Tasm_Lexer_Callbacks;

    on_lexer_error_unexpected_character = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_error_unexpected_character(self.a, pos, state);
        self.b.on_lexer_error_unexpected_character(self.b, pos, state);
    };
    on_lexer_whitespace = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_whitespace(self.a, start_pos, end_pos, state);
        self.b.on_lexer_whitespace(self.b, start_pos, end_pos, state);
    };
    on_lexer_comment = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_comment(self.a, start_pos, end_pos, state);
        self.b.on_lexer_comment(self.b, start_pos, end_pos, state);
    };
    on_lexer_newline = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_newline(self.a, pos, state);
        self.b.on_lexer_newline(self.b, pos, state);
    };
    on_lexer_operator = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_operator(self.a, start_pos, end_pos, state);
        self.b.on_lexer_operator(self.b, start_pos, end_pos, state);
    };
    on_lexer_paren_open = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_paren_open(self.a, pos, state);
        self.b.on_lexer_paren_open(self.b, pos, state);
    };
    on_lexer_paren_close = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_paren_close(self.a, pos, state);
        self.b.on_lexer_paren_close(self.b, pos, state);
    };
    on_lexer_bracket_open = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_bracket_open(self.a, pos, state);
        self.b.on_lexer_bracket_open(self.b, pos, state);
    };
    on_lexer_bracket_close = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_bracket_close(self.a, pos, state);
        self.b.on_lexer_bracket_close(self.b, pos, state);
    };
    on_lexer_number = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_number(self.a, start_pos, end_pos, state);
        self.b.on_lexer_number(self.b, start_pos, end_pos, state);
    };
    on_lexer_symbol = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_symbol(self.a, start_pos, end_pos, state);
        self.b.on_lexer_symbol(self.b, start_pos, end_pos, state);
    };
    on_lexer_string = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
        self := cast(*Composed_Lexer_Callbacks) self_;
        self.a.on_lexer_string(self.a, start_pos, end_pos, state);
        self.b.on_lexer_string(self.b, start_pos, end_pos, state);
    };
}

init_tasm_parser :: (parser: *Tasm_Parser($T), content: string, user_callbacks: *T) {
    parser.content = content;

    parser.callbacks = user_callbacks.base;
    parser.callbacks_data = user_callbacks;

    parser.token_callbacks = Token_Production_Lexer_Callbacks.{
        on_lexer_whitespace = (self_: *Tasm_Lexer_Callbacks, f: s64, l: s64, state: Tasm_Parser_State) { 
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .None };
        },
        on_lexer_string = (self_: *Tasm_Lexer_Callbacks, start_pos: s64, end_pos: s64, state: Tasm_Parser_State) {
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .String, pos = start_pos, len = end_pos - start_pos };
        },
        on_lexer_newline = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Newline, pos = pos, len = 1 };
        },
        on_lexer_comment = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .None };
        },
        on_lexer_operator = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, state: Tasm_Parser_State) { 
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .Operator, pos = f, len = l - f }; 
        },
        on_lexer_paren_open = (self: *Tasm_Lexer_Callbacks, p: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .ParenOpen, pos = p, len = 1 }; 
        },
        on_lexer_paren_close = (self: *Tasm_Lexer_Callbacks, p: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .ParenClose, pos = p, len = 1 }; 
        },
        on_lexer_bracket_open = (self: *Tasm_Lexer_Callbacks, p: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .BracketOpen, pos = p, len = 1 }; 
        },
        on_lexer_bracket_close = (self: *Tasm_Lexer_Callbacks, p: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .BracketClose, pos = p, len = 1 }; 
        },        on_lexer_number = (self: *Tasm_Lexer_Callbacks, f: s64, l: s64, state: Tasm_Parser_State) {
            (cast(*Token_Production_Lexer_Callbacks) self).dest.token = .{ kind = .Number, pos = f, len = l - f }; 
        },
        on_lexer_symbol = (self_: *Tasm_Lexer_Callbacks, f: s64, l: s64, state: Tasm_Parser_State) { 
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Symbol, pos = f, len = l - f }; 
        },
        on_lexer_error_unexpected_character = (self_: *Tasm_Lexer_Callbacks, pos: s64, state: Tasm_Parser_State) {
            self := cast(*Token_Production_Lexer_Callbacks) self_;
            self.dest.token = .{ kind = .Error, pos = pos };
        },
        dest = *parser.base,
    };
    parser.token_callbacks.dest = *parser.base;
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
        } else if parse_procedure_decl(parser) {
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

    parser.callbacks.on_include(parser.callbacks_data, filename, parser.base);

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
        next_token(parser);

        value: string;
        if token.kind == .Number {
            value = to_string(*parser.content[token.pos], token.len);
        } else if token.kind == .Symbol {
            value = to_string(*parser.content[token.pos], token.len);
            // @todo, expressions
        }
        right_pos := parser.pos;
        next_token(parser);

        if token.kind != .Newline {  
            parser.callbacks.on_error(parser.callbacks_data, "while parsing assignment, expected newline", parser.base);
            parser_rollback(parser, mark);
            return false; // error, garbage until the end of the line
        }

        parser.callbacks.on_symbol_assignment(parser.callbacks_data, symbol, op, value, "", to_string(*parser.content[right_pos], token.pos - right_pos), parser.base);
        return true;
    } else if token.kind == .Operator {
        op = to_string(*parser.content[token.pos], token.len);
        if op != "=" {
            parser_rollback(parser, mark);
            return false;
        }
        next_token(parser);

        if token.kind != .Number {
            // @todo missing, support for numeric expressions here. Like:
            //
            //   Offset = <Variable> + 43
            //

            parser.callbacks.on_error(parser.callbacks_data, "while parsing assignment, expected number", parser.base);
            parser_rollback(parser, mark);
            return false;
        }
        number := to_string(*parser.content[token.pos], token.len);
        right_pos := parser.pos;
        next_token(parser);
    
        if token.kind != .Newline {  
            parser.callbacks.on_error(parser.callbacks_data, "while parsing assignment, expected newline", parser.base);
            parser_rollback(parser, mark);
            return false; // error, garbage until the end of the line
        }
    
        parser.callbacks.on_symbol_assignment(parser.callbacks_data, symbol, op, number, "", to_string(*parser.content[right_pos], token.pos - right_pos), parser.base);
        return true;

    }
    parser_rollback(parser, mark);
    return false;
}

parse_procedure_decl :: (parser: *Tasm_Parser) -> found: bool {
/*
Ideal mode T310 syntax:

PROC [[language modifier] language] name [distance] 
[ARG argument_list] [RETqRNS item_list] 
[LOCAL argument_list] 
[USES item_list] 
ENDP 
*/
// watch out that these could be nested!

    using parser;

    if token.kind != .Symbol {
        return false;
    }
    keyword := to_string(*parser.content[token.pos], token.len);
    if !equal_nocase(keyword, "PROC") {
        return false;
    }
    next_token(parser);

    mark := parser_mark(parser);

    if token.kind != .Symbol {
        parser.callbacks.on_error(parser.callbacks_data, "while parsing PROC decl, expected [[language modifier] language] name", parser.base);
        return false;
    }

    // I'm guessing Impulse Tracker never uses language modifiers and language and we just have the name here.
    name := to_string(*parser.content[token.pos], token.len);
    next_token(parser);

    distance := "implicit-distance";
    if token.kind == .Symbol {
        distance = to_string(*parser.content[token.pos], token.len);
        next_token(parser);
    }
    
    if token.kind != .Newline {
        parser.callbacks.on_error(parser.callbacks_data, "while parsing PROC decl, expected newline after name [distance]", parser.base);
        return false;
    }

    parser.callbacks.on_procedure_decl(parser.callbacks_data, name, distance, parser.base);

    next_token(parser);

    // let's eat all the lines.
    num_lines := 0;
    while true {
        if parse_procedure_decl(parser) {
        } else {
            if token.kind == .Symbol {
                keyword = to_string(*parser.content[token.pos], token.len);
                if equal_nocase(keyword , "ENDP") {
                    // we've reached the end of the procedure
                    next_token(parser);
                    if token.kind != .Symbol {
                        parser.callbacks.on_error(parser.callbacks_data, "while parsing ENDP, expected function name", parser.base);
                        return false;
                    }
                    if !equal_nocase(to_string(*parser.content[token.pos], token.len), name) {
                        parser.callbacks.on_error(parser.callbacks_data, "while parsing ENDP, expected the same function name", parser.base);
                        return false;
                    }
                    next_token(parser);

                    if token.kind != .Newline {
                        parser.callbacks.on_error(parser.callbacks_data, "while parsing PROC decl, expected newline after name [distance]", parser.base);
                        return false;                        
                    }
                    parser.callbacks.on_procedure_decl_end(parser.callbacks_data, name, num_lines, parser.base);
                    break;
                }
                next_token(parser);
            }
            while token.kind != .Newline {
                next_token(parser); // ignore
            }
            next_token(parser);
            num_lines += 1;
        }
    }
        
    return true;
}

next_token :: (parser: *Tasm_Parser) -> found: bool {
    while true {
        if !tasm_lexer_next(*parser.base, *parser.lexer_callbacks.base) { 
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

tasm_lexer_next :: (parser: *Tasm_Parser_State, callbacks: *Tasm_Lexer_Callbacks) -> found: bool {
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
            return true;

        case #char "\r";
            start := parser.pos;
            parser.pos += 1;
            c := parser.content[parser.pos];
            if c == #char "\n" {
                start = parser.pos;
                parser.pos += 1;
                callbacks.on_lexer_newline(callbacks, start, parser);
                return true;
            } else {
                callbacks.on_lexer_whitespace(callbacks, start, parser.pos, parser);
                return true;
            }

        case #char "\n"; {
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_newline(callbacks, start, parser);
            return true;
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
            return true;

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

            // scan for the boundary and radix
            end := parser.pos;

            is_numeric_boundary :: (c: u8) -> bool {
                return !(#char "0" <= c && c <= #char "9") &&
                       !(#char "A" <= c && c <= #char "F") &&
                       !(#char "a" <= c && c <= #char "f") &&
                       !(#char "h" == c || c == #char "H") &&
                       !(#char "b" == c || c == #char "B");
            }
            while true {
                c := parser.content[end];
                if is_numeric_boundary(c) {
                    break;
                }
                end += 1;
            }
            radix := parser.content[end - 1];
            if radix == #char "h" || radix == #char "H" {
                is_numeric_character :: (c: u8) -> bool {
                    return (#char "0" <= c && c <= #char "9") || 
                           (#char "A" <= c && c <= #char "F") ||
                           (#char "a" <= c && c <= #char "f");
                }
                while parser.pos < end - 1 {
                    c := parser.content[parser.pos];
                    if !is_numeric_character(c) {
                        break;
                    }
                    parser.pos += 1;
                }
                if parser.pos != end - 1 {
                    callbacks.on_lexer_error_unexpected_character(callbacks, parser.pos, parser);
                }                           
                parser.pos += 1;
                callbacks.on_lexer_number(callbacks, start, end, parser);
            } else if radix == #char "b" || radix == #char "B" {
                is_numeric_character :: (c: u8) -> bool {
                    return (#char "0" <= c && c <= #char "1");
                }
                while parser.pos < end - 1 {
                    c := parser.content[parser.pos];
                    if !is_numeric_character(c) {
                        break;
                    }
                    parser.pos += 1;
                }
                if parser.pos != end - 1 {
                    callbacks.on_lexer_error_unexpected_character(callbacks, parser.pos, parser);
                }           
                parser.pos += 1;
                callbacks.on_lexer_number(callbacks, start, end, parser);
                return true;
                
            } else {
                is_numeric_character :: (c: u8) -> bool {
                    return (#char "0" <= c && c <= #char "9");
                }
                while parser.pos < end {
                    c := parser.content[parser.pos];
                    if !is_numeric_character(c) {
                        break;
                    }
                    parser.pos += 1;
                }
            
                if parser.pos != end {
                    callbacks.on_lexer_error_unexpected_character(callbacks, parser.pos, parser);
                    return true;
                } else {            
                    callbacks.on_lexer_number(callbacks, start, parser.pos, parser);
                    return true;
                }
            }

        case #char ","; #through;
        case #char "-"; #through;
        case #char "+"; #through;
        case #char ":"; #through;
        case #char "?"; #through;
        case #char "*"; #through;
        case #char "/"; #through;
        case #char "$"; #through;
        case #char "=";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_operator(callbacks, start, parser.pos, parser);
            return true;

        case #char "(";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_paren_open(callbacks, start, parser);
            return true;

        case #char ")";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_paren_close(callbacks, start, parser);
            return true;

        case #char "[";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_bracket_open(callbacks, start, parser);
            return true;

        case #char "]";
            start := parser.pos;
            parser.pos += 1;
            callbacks.on_lexer_bracket_close(callbacks, start, parser);
            return true;

        case #char "'"; #through;
        case #char "\"";
            start := parser.pos;
            quote := parser.content[parser.pos];
            parser.pos += 1;
            while true {
                c := parser.content[parser.pos];
                if c == quote {
                    if parser.content[parser.pos + 1] == quote {
                        parser.pos += 2;
                    } else {
                        parser.pos += 1;
                        break;
                    }
                } else {
                    parser.pos += 1;
                }
            }
            callbacks.on_lexer_string(callbacks, start, parser.pos, parser);
            return true;

        // multiline COMMENT initial:
        case #char "c"; #through;
        case #char "C";
            is_printable_character :: (c: u8) -> bool {
                return 0x21 <= c && c <= 0x7e;
            }

            start := parser.pos;
            i := 1;
            while true {
                c := parser.content[start + i];
                if !c {
                    break;
                }
                if !is_printable_character(c) {
                    break;
                }
                i += 1;
            }
            if equal_nocase("COMMENT", to_string(*parser.content[start], i)) {
                while true {
                    c := parser.content[start + i];
                    if c != #char " " && c != #char "\t" {
                        break;
                    }
                    i += 1;
                }
                c := parser.content[start + i];
                i += 1;

                if is_printable_character(c) {
                     comment_delimiter := c;
                
                    while true {
                        c := parser.content[start + i];
                        if !c {
                            callbacks.on_lexer_error_unexpected_character(callbacks, start, parser);
                            return false;
                        }
                        if c == comment_delimiter {
                            break;
                        }
                        i += 1;
                    }
                    parser.pos = start + i + 1;
                    end := parser.pos;
                    callbacks.on_lexer_comment(callbacks, start, end, parser);
                    return true;
                }
            }
    }

    is_keyword_character :: (c: u8) -> bool {
        return (#char "A" <= c && c <= #char "Z") || (#char "a" <= c && c <= #char "z") || (#char "0" <= c && c <= #char "9") || c == #char "_" || c == #char "." || c == #char "@";
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

    return true;
}

