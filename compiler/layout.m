%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2001-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Definitions of Mercury types for representing layout structures within
% the compiler. Layout structures are generated by the compiler, and are
% used by the parts of the runtime system that need to look at the stacks
% (and sometimes the registers) and make sense of their contents. The parts
% of the runtime system that need to do this include exception handling,
% the debugger, the deep profiler and (eventually) the accurate garbage
% collector.
%
% When output by layout_out.m, values of most these types will correspond
% to the C types defined in runtime/mercury_stack_layout.h or
% runtime/mercury_deep_profiling.h; the documentation of those types
% can be found there. The names of the C types are listed next to the
% function symbol whose arguments represent their contents.
%
% The code to generate values of these types is in stack_layout.m and
% deep_profiling.m.
%
% This module should be, but as yet isn't, independent of whether we are
% compiling to LLDS or MLDS.
%
% Author: zs.

%-----------------------------------------------------------------------------%

:- module ll_backend__layout.

:- interface.

:- import_module hlds__hlds_pred.
:- import_module libs__trace_params.
:- import_module ll_backend__llds.
:- import_module mdbcomp__prim_data.
:- import_module parse_tree__prog_data.

:- import_module assoc_list.
:- import_module bool.
:- import_module list.
:- import_module std_util.

    % This type is for strings which may contain embedded null characters.
:- type string_with_0s ---> string_with_0s(string).

:- type layout_data
    --->    label_layout_data(      % defines MR_Label_Layout
                proc_label              :: proc_label,
                label_num               :: int,
                proc_layout_name        :: layout_name,
                maybe_port              :: maybe(trace_port),
                maybe_is_hidden         :: maybe(bool),
                label_num_in_module     :: int,
                maybe_goal_path         :: maybe(int), % offset
                maybe_var_info          :: maybe(label_var_info)
            )
    ;       proc_layout_data(       % defines MR_Proc_Layout
                proc_layout_label       :: rtti_proc_label,
                proc_layout_trav        :: proc_layout_stack_traversal,
                proc_layout_more        :: maybe_proc_id_and_more
            )
    ;       module_layout_data(     % defines MR_Module_Layout
                module_name             :: module_name,
                string_table_size       :: int,
                string_table            :: string_with_0s,
                proc_layout_names       :: list(layout_name),
                file_layouts            :: list(file_layout_data),
                trace_level             :: trace_level,
                suppressed_events       :: int,
                num_label_exec_count    :: int
            )
    ;       closure_proc_id_data(       % defines MR_Closure_Id
                caller_proc_label       :: proc_label,
                caller_closure_seq_no   :: int,
                closure_proc_label      :: proc_label,
                closure_module_name     :: module_name,
                closure_file_name       :: string,
                closure_line_number     :: int,
                closure_origin          :: pred_origin,
                closure_goal_path       :: string
            )
    ;       table_io_decl_data(
                table_io_decl_proc_ptr  :: rtti_proc_label,
                table_io_decl_kind      :: proc_layout_kind,
                table_io_decl_num_ptis  :: int,
                table_io_decl_ptis      :: rval,
                                        % pseudo-typeinfos for headvars
                table_io_decl_type_params :: rval
            )
    ;       table_gen_data(
                table_gen_proc_ptr      :: rtti_proc_label,
                table_gen_num_inputs    :: int,
                table_gen_num_outputs   :: int,
                table_gen_steps         :: list(table_trie_step),
                table_gen_ptis          :: rval,
                                        % pseudo-typeinfos for headvars
                table_gen_type_params   :: rval
            ).

:- type label_var_info
    --->    label_var_info(         % part of MR_Label_Layout
                encoded_var_count       :: int,
                locns_types             :: rval,
                var_nums                :: rval,
                type_params             :: rval
            ).

:- type proc_layout_stack_traversal     % defines MR_Stack_Traversal
    --->    proc_layout_stack_traversal(
                entry_label             :: maybe(label),
                                        % The proc entry label; will be
                                        % `no' if we don't have static
                                        % code addresses.
                succip_slot             :: maybe(int),
                stack_slot_count        :: int,
                detism                  :: determinism
            ).

    % The deep_slot_info gives the stack slot numbers that hold
    % the values returned by the call port code, which are needed to let
    % exception.throw perform the work we need to do at the excp port.
    % The old_outermost slot is needed only with the save/restore approach;
    % the old_outermost field contain -1 otherwise. All fields will contain
    % -1 if the variables are never saved on the stack because the
    % predicate makes no calls (in which case it cannot throw exceptions,
    % because to do that it would need to call exception.throw, directly or
    % indirectly.)
:- type deep_excp_slots
    --->    deep_excp_slots(
                top_csd                 :: int,
                middle_csd              :: int,
                old_outermost           :: int
            ).

:- type proc_layout_proc_static
    --->    proc_layout_proc_static(
                hlds_proc_static        :: hlds_proc_static,
                deep_excp_slots         :: deep_excp_slots
            ).

:- type maybe_proc_id_and_more
    --->    no_proc_id
    ;       proc_id(
                maybe(proc_layout_proc_static),
                maybe(proc_layout_exec_trace)
            ).

:- type proc_layout_exec_trace          % defines MR_Exec_Trace
    --->    proc_layout_exec_trace(
                call_label_layout       :: layout_name,
                proc_body_bytes         :: list(int),
                                        % The procedure body represented as
                                        % a list of bytecodes.

                maybe_table_info        :: maybe(layout_name),
                head_var_nums           :: list(int),
                                        % The variable numbers of the
                                        % head variables, including the
                                        % ones added by the compiler,
                                        % in order. The length of the
                                        % list must be the same as the
                                        % procedure's arity.

                var_names               :: list(int),
                                        % Each variable name is an offset into
                                        % the module's string table.

                max_var_num             :: int,
                max_r_num               :: int,
                maybe_from_full_slot    :: maybe(int),
                maybe_io_seq_slot       :: maybe(int),
                maybe_trail_slot        :: maybe(int),
                maybe_maxfr_slot        :: maybe(int),
                eval_method             :: eval_method,
                maybe_call_table_slot   :: maybe(int),
                eff_trace_level         :: trace_level,
                exec_trace_flags        :: int
            ).

:- type file_layout_data
    --->    file_layout_data(
                file_name               :: string,
                line_no_label_list      :: assoc_list(int, layout_name)
            ).

%-----------------------------------------------------------------------------%

:- type layout_name
    --->    label_layout(proc_label, int, label_vars)
    ;       proc_layout(rtti_proc_label, proc_layout_kind)
            % A proc layout structure for stack tracing, accurate gc,
            % deep profiling and/or execution tracing.
    ;       proc_layout_exec_trace(rtti_proc_label)
    ;       proc_layout_head_var_nums(rtti_proc_label)
            % A vector of variable numbers, containing the numbers of the
            % procedure's head variables, including the ones generated by
            % the compiler.
    ;       proc_layout_var_names(rtti_proc_label)
            % A vector of variable names (represented as offsets into
            % the string table) for a procedure layout structure.
    ;       proc_layout_body_bytecode(rtti_proc_label)
    ;       table_io_decl(rtti_proc_label)
    ;       table_gen_info(rtti_proc_label)
    ;       table_gen_enum_params(rtti_proc_label)
    ;       table_gen_steps(rtti_proc_label)
    ;       closure_proc_id(proc_label, int, proc_label)
    ;       file_layout(module_name, int)
    ;       file_layout_line_number_vector(module_name, int)
    ;       file_layout_label_layout_vector(module_name, int)
    ;       module_layout_string_table(module_name)
    ;       module_layout_file_vector(module_name)
    ;       module_layout_proc_vector(module_name)
    ;       module_layout_label_exec_count(module_name, int)
    ;       module_layout(module_name)
    ;       proc_static(rtti_proc_label)
    ;       proc_static_call_sites(rtti_proc_label).

:- type label_vars
    --->    label_has_var_info
    ;       label_has_no_var_info.

:- type proc_layout_kind
    --->    proc_layout_traversal
    ;       proc_layout_proc_id(proc_layout_user_or_uci).

:- type proc_layout_user_or_uci
    --->    user
    ;       uci.

%-----------------------------------------------------------------------------%
