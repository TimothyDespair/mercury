%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2009 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: ml_tailcall.m
% Authors: fjh, pbone
%
% This module is an MLDS-to-MLDS transformation that marks function calls
% as tail calls whenever it is safe to do so, based on the assumptions
% described below.
%
% A function call can safely be marked as a tail call if all three of the
% following conditions are satisfied:
%
% 1 it occurs in a position which would fall through into the end of the
%   function body or to a `return' statement,
%
% 2 the lvalues in which the return value(s) from the `call' will be placed
%   are the same as the value(s) returned by the `return', and these lvalues
%   are all local variables,
%
% 3 the function's local variables do not need to be live for that call.
%
% For (2), we just assume (rather than checking) that any variables returned
% by the `return' statement are local variables. This assumption is true
% for the MLDS code generated by ml_code_gen.m.
%
% For (3), we assume that the addresses of local variables and nested functions
% are only ever passed down to other functions (and used to assign to the local
% variable or to call the nested function), so that here we only need to check
% if the potential tail call uses such addresses, not whether such addresses
% were taken in earlier calls. That is, if the addresses of locals were taken
% in earlier calls from the same function, we assume that these addresses
% will not be saved (on the heap, or in global variables, etc.) and used after
% those earlier calls have returned. This assumption is true for the MLDS code
% generated by ml_code_gen.m.
%
% We just mark tailcalls in this module here. The actual tailcall optimization
% (turn self-tailcalls into loops) is done in ml_optimize. Individual backends
% may wish to treat tailcalls separately if there is any backend support
% for them.
%
% Note that ml_call_gen.m will also mark calls to procedures with determinism
% `erroneous' as `no_return_call's (a special case of tail calls)
% when it generates them.
%
% Note also that the job that this module does on the MLDS is very similar
% to the job done by mark_tail_calls.m on the HLDS. The two are separate
% because with the MLDS backend, figuring out which recursive calls will end up
% as tail calls cannot be done without doing a large part of the job of the
% HLDS-to-MLDS code generator. Nevertheless, what parts *can* be kept in common
% between this module and mark_tail_calls.m *should* be kept in common.
% This is why this module calls predicates in mark_tail_calls.m to construct
% the warning messages it generates.
%
%-----------------------------------------------------------------------------%

:- module ml_backend.ml_tailcall.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module ml_backend.mlds.
:- import_module parse_tree.
:- import_module parse_tree.error_util.
:- import_module libs.
:- import_module libs.globals.

:- import_module list.

%-----------------------------------------------------------------------------%

    % Traverse the MLDS, marking all optimizable tail calls as tail calls.
    %
    % If enabled, warn for calls that "look like" tail calls, but aren't.
    %
:- pred ml_mark_tailcalls(globals::in, module_info::in, list(error_spec)::out,
    mlds::in, mlds::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds.hlds_pred.
:- import_module hlds.mark_tail_calls.
:- import_module libs.compiler_util.
:- import_module libs.options.
:- import_module mdbcomp.
:- import_module mdbcomp.sym_name.
:- import_module ml_backend.ml_util.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_data_pragma.

:- import_module bool.
:- import_module int.
:- import_module maybe.
:- import_module require.

%-----------------------------------------------------------------------------%

ml_mark_tailcalls(Globals, ModuleInfo, Specs, !MLDS) :-
    Defns0 = !.MLDS ^ mlds_defns,
    ModuleName = mercury_module_name_to_mlds(!.MLDS ^ mlds_name),
    globals.lookup_bool_option(Globals, warn_non_tail_recursion,
        WarnTailCallsBool),
    (
        WarnTailCallsBool = yes,
        WarnTailCalls = warn_tail_calls
    ;
        WarnTailCallsBool = no,
        WarnTailCalls = do_not_warn_tail_calls
    ),
    mark_tailcalls_in_defns(ModuleInfo, ModuleName, WarnTailCalls,
        Defns0, Defns, [], Specs),
    !MLDS ^ mlds_defns := Defns.

%-----------------------------------------------------------------------------%

    % The algorithm works by walking backwards through each function in the
    % MLDS.  It tracks (via at_tail) whether the current position in the
    % function's body is a tail position.

    % The `at_tail' type indicates whether or not a statement is at a tail
    % position, i.e. is followed by a return statement or the end of the
    % function, and if so, specifies the return values (if any) in the return
    % statement.
    %
    % If a subgoal is not at a tail position, then this type also tracks
    % whether a recursive call has been seen (backwards) along this
    % execution path.  This is used to avoid creating warnings for further
    % recursive calls.
    % XXX We should NOT create warnings for non-tail-recursive recursive calls
    % in this module, because the MLDS has no information about the location
    % of any disable_warnings scope in the HLDS. The mark_tail_calls.m module
    % also generates the same warnings, but it does not suffer from this
    % problem because it operates on the HLDS.
    %
    % The algorithm must track this rather than stop walking through the
    % function body as it may encounter a return statement and therefore
    % find more tailcalls.
    %
:- type at_tail
    --->        at_tail(list(mlds_rval))
    ;           not_at_tail_seen_reccall
    ;           not_at_tail_have_not_seen_reccall.

:- pred not_at_tail(at_tail::in, at_tail::out) is det.

not_at_tail(at_tail(_), not_at_tail_have_not_seen_reccall).
not_at_tail(not_at_tail_seen_reccall, not_at_tail_seen_reccall).
not_at_tail(not_at_tail_have_not_seen_reccall,
    not_at_tail_have_not_seen_reccall).

    % The `locals' type contains a list of local definitions
    % which are in scope.
:- type locals == list(local_defns).
:- type local_defns
    --->    local_params(mlds_arguments)
    ;       local_defns(list(mlds_defn)).

:- type found_recursive_call
    --->    found_recursive_call
    ;       not_found_recursive_call.

:- type tc_in_body_info
    --->    tc_in_body_info(
                tibi_found                  :: found_recursive_call,
                tibi_specs                  :: list(error_spec)
            ).

%-----------------------------------------------------------------------------%

:- type tailcall_info
    --->    tailcall_info(
                tci_module_info             :: module_info,
                tci_module_name             :: mlds_module_name,
                tci_function_name           :: mlds_entity_name,
                tci_maybe_pred_info         :: maybe(pred_info),
                tci_locals                  :: locals,
                tci_warn_tail_calls         :: warn_tail_calls,
                tci_maybe_require_tailrec   :: maybe(require_tail_recursion)
            ).

:- type warn_tail_calls
    --->    warn_tail_calls
    ;       do_not_warn_tail_calls.

%-----------------------------------------------------------------------------%

% mark_tailcalls_in_defns:
% mark_tailcalls_in_defn:
%   Recursively process the definition(s),
%   marking each optimizable tail call in them as a tail call.
%
% mark_tailcalls_in_maybe_statement:
% mark_tailcalls_in_statements:
% mark_tailcalls_in_statement:
% mark_tailcalls_in_stmt:
% mark_tailcalls_in_case:
% mark_tailcalls_in_default:
%   Recursively process the statement(s) and their components,
%   marking each optimizable tail call in them as a tail call.
%   The `AtTail' argument indicates whether or not this construct
%   is in a tail call position, and if not, whether we *have* seen a tailcall
%   earlier in the backwards traversal (i.e. after the current position,
%   in terms of forward execution).
%   The `Locals' argument contains the local definitions which are in scope
%   at the current point.

:- pred mark_tailcalls_in_defns(module_info::in, mlds_module_name::in,
    warn_tail_calls::in, list(mlds_defn)::in, list(mlds_defn)::out,
    list(error_spec)::in, list(error_spec)::out) is det.

mark_tailcalls_in_defns(ModuleInfo, ModuleName, WarnTailCalls,
        !Defns, !Specs) :-
    list.map_foldl(
        mark_tailcalls_in_defn(ModuleInfo, ModuleName, WarnTailCalls),
        !Defns, !Specs).

:- pred mark_tailcalls_in_defn(module_info::in, mlds_module_name::in,
    warn_tail_calls::in, mlds_defn::in, mlds_defn::out,
    list(error_spec)::in, list(error_spec)::out) is det.

mark_tailcalls_in_defn(ModuleInfo, ModuleName, WarnTailCalls,
        Defn0, Defn, !Specs) :-
    Defn0 = mlds_defn(Name, Context, Flags, DefnBody0),
    (
        DefnBody0 = mlds_function(MaybePredProcId, Params, FuncBody0,
            Attributes, EnvVarNames, MaybeRequireTailrecInfo),
        % Compute the initial values of the `Locals' and `AtTail' arguments.
        Params = mlds_func_params(Args, RetTypes),
        Locals = [local_params(Args)],
        (
            RetTypes = [],
            AtTail = at_tail([])
        ;
            RetTypes = [_ | _],
            AtTail = not_at_tail_have_not_seen_reccall
        ),
        (
            MaybePredProcId = yes(proc(PredId, _)),
            module_info_pred_info(ModuleInfo, PredId, PredInfo),
            MaybePredInfo = yes(PredInfo)
        ;
            MaybePredProcId = no,
            MaybePredInfo = no
        ),
        TCallInfo = tailcall_info(ModuleInfo, ModuleName, Name,
            MaybePredInfo, Locals, WarnTailCalls, MaybeRequireTailrecInfo),
        mark_tailcalls_in_function_body(TCallInfo, AtTail,
            FuncBody0, FuncBody, !Specs),
        DefnBody = mlds_function(MaybePredProcId, Params, FuncBody,
            Attributes, EnvVarNames, MaybeRequireTailrecInfo),
        Defn = mlds_defn(Name, Context, Flags, DefnBody)
    ;
        DefnBody0 = mlds_data(_, _, _),
        Defn = Defn0
    ;
        DefnBody0 = mlds_class(ClassDefn0),
        ClassDefn0 = mlds_class_defn(Kind, Imports, BaseClasses, Implements,
            TypeParams, CtorDefns0, MemberDefns0),
        mark_tailcalls_in_defns(ModuleInfo, ModuleName, WarnTailCalls,
            CtorDefns0, CtorDefns, !Specs),
        mark_tailcalls_in_defns(ModuleInfo, ModuleName, WarnTailCalls,
            MemberDefns0, MemberDefns, !Specs),
        ClassDefn = mlds_class_defn(Kind, Imports, BaseClasses, Implements,
            TypeParams, CtorDefns, MemberDefns),
        DefnBody = mlds_class(ClassDefn),
        Defn = mlds_defn(Name, Context, Flags, DefnBody)
    ).

:- pred mark_tailcalls_in_function_body(tailcall_info::in, at_tail::in,
    mlds_function_body::in, mlds_function_body::out,
    list(error_spec)::in, list(error_spec)::out) is det.

mark_tailcalls_in_function_body(TCallInfo, AtTail, Body0, Body, !Specs) :-
    (
        Body0 = body_external,
        Body = body_external
    ;
        Body0 = body_defined_here(Statement0),
        InBodyInfo0 = tc_in_body_info(not_found_recursive_call, !.Specs),
        mark_tailcalls_in_statement(TCallInfo, AtTail, _,
            Statement0, Statement, InBodyInfo0, InBodyInfo),
        InBodyInfo = tc_in_body_info(FoundRecCall, !:Specs),
        Body = body_defined_here(Statement),
        (
            FoundRecCall = found_recursive_call
        ;
            FoundRecCall = not_found_recursive_call,
            MaybeRequireTailrecInfo = TCallInfo ^ tci_maybe_require_tailrec,
            (
                MaybeRequireTailrecInfo = yes(RequireTailrecInfo),
                ( RequireTailrecInfo = suppress_tailrec_warnings(Context)
                ; RequireTailrecInfo = enable_tailrec_warnings(_, _, Context)
                ),
                MaybePredInfo = TCallInfo ^ tci_maybe_pred_info,
                (
                    MaybePredInfo = yes(PredInfo),
                    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
                    pred_info_get_name(PredInfo, Name),
                    pred_info_get_orig_arity(PredInfo, Arity),
                    SymName = unqualified(Name), 
                    SimpleCallId = simple_call_id(PredOrFunc, SymName, Arity),
                    add_message_for_no_tail_or_nontail_recursive_calls(
                        SimpleCallId, Context, !Specs)
                ;
                    % If this function wasn't generated from a Mercury
                    % predicate, then don't create this warning.
                    % This cannot happen anyway because the require tail
                    % recursion pragma cannot be attached to predicates
                    % that don't exist.
                    MaybePredInfo = no
                )
            ;
                MaybeRequireTailrecInfo = no
            )
        )
    ).

:- pred mark_tailcalls_in_maybe_statement(tailcall_info::in,
    at_tail::in, at_tail::out, maybe(statement)::in, maybe(statement)::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_maybe_statement(TCallInfo, !AtTail,
        MaybeStatement0, MaybeStatement, !InBodyInfo) :-
    (
        MaybeStatement0 = no,
        MaybeStatement = no
    ;
        MaybeStatement0 = yes(Statement0),
        mark_tailcalls_in_statement(TCallInfo, !AtTail, Statement0, Statement,
            !InBodyInfo),
        MaybeStatement = yes(Statement)
    ).

:- pred mark_tailcalls_in_statements(tailcall_info::in,
    at_tail::in, at_tail::out, list(statement)::in, list(statement)::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_statements(_, !AtTail, [], [], !InBodyInfo).
mark_tailcalls_in_statements(TCallInfo, !AtTail,
        [Stmt0 | Stmts0], [Stmt | Stmts], !InBodyInfo) :-
    mark_tailcalls_in_statements(TCallInfo, !AtTail, Stmts0, Stmts,
        !InBodyInfo),
    mark_tailcalls_in_statement(TCallInfo, !AtTail, Stmt0, Stmt,
        !InBodyInfo).

:- pred mark_tailcalls_in_statement(tailcall_info::in,
    at_tail::in, at_tail::out, statement::in, statement::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_statement(TCallInfo, !AtTail, !Statement, !InBodyInfo) :-
    !.Statement = statement(Stmt0, Context),
    mark_tailcalls_in_stmt(TCallInfo, Context, !AtTail, Stmt0, Stmt,
        !InBodyInfo),
    !:Statement = statement(Stmt, Context).

:- pred mark_tailcalls_in_stmt(tailcall_info::in, mlds_context::in,
    at_tail::in, at_tail::out, mlds_stmt::in, mlds_stmt::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_stmt(TCallInfo, Context, AtTailAfter0, AtTailBefore,
        Stmt0, Stmt, !InBodyInfo) :-
    (
        Stmt0 = ml_stmt_block(Defns0, Statements0),
        % Whenever we encounter a block statement, we recursively mark
        % tailcalls in any nested functions defined in that block.
        % We also need to add any local definitions in that block to the list
        % of currently visible local declarations before processing the
        % statements in that block. The statement list will be in a tail
        % position iff the block is in a tail position.
        ModuleInfo = TCallInfo ^ tci_module_info,
        ModuleName = TCallInfo ^ tci_module_name,
        WarnTailCalls = TCallInfo ^ tci_warn_tail_calls,
        Specs0 = !.InBodyInfo ^ tibi_specs,
        mark_tailcalls_in_defns(ModuleInfo, ModuleName, WarnTailCalls,
            Defns0, Defns, Specs0, Specs),
        !InBodyInfo ^ tibi_specs := Specs,
        Locals = TCallInfo ^ tci_locals,
        NewTCallInfo = TCallInfo ^ tci_locals := [local_defns(Defns) | Locals],
        mark_tailcalls_in_statements(NewTCallInfo, AtTailAfter0, AtTailBefore,
            Statements0, Statements, !InBodyInfo),
        Stmt = ml_stmt_block(Defns, Statements)
    ;
        Stmt0 = ml_stmt_while(Kind, Rval, Statement0),
        % The statement in the body of a while loop is never in a tail
        % position.
        not_at_tail(AtTailAfter0, AtTailAfter),
        mark_tailcalls_in_statement(TCallInfo, AtTailAfter, AtTailBefore0,
            Statement0, Statement, !InBodyInfo),
        % Neither is any statement before the loop.
        not_at_tail(AtTailBefore0, AtTailBefore),
        Stmt = ml_stmt_while(Kind, Rval, Statement)
    ;
        Stmt0 = ml_stmt_if_then_else(Cond, Then0, MaybeElse0),
        % Both the `then' and the `else' parts of an if-then-else are in a
        % tail position iff the if-then-else is in a tail position.
        mark_tailcalls_in_statement(TCallInfo,
            AtTailAfter0, AtTailBeforeThen, Then0, Then, !InBodyInfo),
        mark_tailcalls_in_maybe_statement(TCallInfo,
            AtTailAfter0, AtTailBeforeElse, MaybeElse0, MaybeElse,
            !InBodyInfo),
        ( if
            ( AtTailBeforeThen = not_at_tail_seen_reccall
            ; AtTailBeforeElse = not_at_tail_seen_reccall
            )
        then
            AtTailBefore = not_at_tail_seen_reccall
        else
            AtTailBefore = not_at_tail_have_not_seen_reccall
        ),
        Stmt = ml_stmt_if_then_else(Cond, Then, MaybeElse)
    ;
        Stmt0 = ml_stmt_switch(Type, Val, Range, Cases0, Default0),
        % All of the cases of a switch (including the default) are in a
        % tail position iff the switch is in a tail position.
        mark_tailcalls_in_cases(TCallInfo, AtTailAfter0, AtTailBeforeCases,
            Cases0, Cases, !InBodyInfo),
        mark_tailcalls_in_default(TCallInfo, AtTailAfter0, AtTailBeforeDefault,
            Default0, Default, !InBodyInfo),
        ( if
            % Have we seen a tailcall, in either a case or in the default?
            (
                find_first_match(unify(not_at_tail_seen_reccall),
                    AtTailBeforeCases, _)
            ;
                AtTailBeforeDefault = not_at_tail_seen_reccall
            )
        then
            AtTailBefore = not_at_tail_seen_reccall
        else
            AtTailBefore = not_at_tail_have_not_seen_reccall
        ),
        Stmt = ml_stmt_switch(Type, Val, Range, Cases, Default)
    ;
        Stmt0 = ml_stmt_call(_, _, _, _, _, _),
        mark_tailcalls_in_stmt_call(TCallInfo, Context,
            AtTailAfter0, AtTailBefore, Stmt0, Stmt, !InBodyInfo)
    ;
        Stmt0 = ml_stmt_try_commit(Ref, Statement0, Handler0),
        % Both the statement inside a `try_commit' and the handler are in
        % tail call position iff the `try_commit' statement is in a tail call
        % position.
        mark_tailcalls_in_statement(TCallInfo, AtTailAfter0, _,
            Statement0, Statement, !InBodyInfo),
        mark_tailcalls_in_statement(TCallInfo, AtTailAfter0, _,
            Handler0, Handler, !InBodyInfo),
        AtTailBefore = not_at_tail_have_not_seen_reccall,
        Stmt = ml_stmt_try_commit(Ref, Statement, Handler)
    ;
        ( Stmt0 = ml_stmt_goto(_)
        ; Stmt0 = ml_stmt_computed_goto(_, _)
        ; Stmt0 = ml_stmt_do_commit(_Ref)
        ; Stmt0 = ml_stmt_atomic(_)
        ),
        not_at_tail(AtTailAfter0, AtTailBefore),
        Stmt = Stmt0
    ;
        Stmt0 = ml_stmt_label(_),
        AtTailBefore = AtTailAfter0,
        Stmt = Stmt0
    ;
        Stmt0 = ml_stmt_return(ReturnVals),
        % The statement before a return statement is in a tail position.
        AtTailBefore = at_tail(ReturnVals),
        Stmt = Stmt0
    ).

:- inst ml_stmt_call
    --->    ml_stmt_call(ground, ground, ground, ground, ground, ground).

:- pred mark_tailcalls_in_stmt_call(tailcall_info::in, mlds_context::in,
    at_tail::in, at_tail::out, mlds_stmt::in(ml_stmt_call), mlds_stmt::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_stmt_call(TCallInfo, Context, AtTailAfter, AtTailBefore,
        Stmt0, Stmt, !InBodyInfo) :-
    Stmt0 = ml_stmt_call(Sig, Func, Obj, Args, ReturnLvals, CallKind0),
    ModuleName = TCallInfo ^ tci_module_name,
    FunctionName = TCallInfo ^ tci_function_name,
    QualName = qual(ModuleName, module_qual, FunctionName),
    Locals = TCallInfo ^ tci_locals,

    % Check if we can mark this call as a tail call.
    ( if
        CallKind0 = ordinary_call,
        Func = ml_const(mlconst_code_addr(CodeAddr)),
        call_is_recursive(QualName, Stmt0)
    then
        !InBodyInfo ^ tibi_found := found_recursive_call,
        ( if
            % We must be in a tail position.
            AtTailAfter = at_tail(ReturnRvals),

            % The values returned in this call must match those returned
            % by the `return' statement that follows.
            match_return_vals(ReturnRvals, ReturnLvals),

            % The call must not take the address of any local variables
            % or nested functions.
            check_maybe_rval(Obj, Locals) = will_not_yield_dangling_stack_ref,
            check_rvals(Args, Locals) = will_not_yield_dangling_stack_ref,

            % The call must not be to a function nested within this function.
            check_rval(Func, Locals) = will_not_yield_dangling_stack_ref
        then
            % Mark this call as a tail call.
            Stmt = ml_stmt_call(Sig, Func, Obj, Args, ReturnLvals, tail_call),
            AtTailBefore = not_at_tail_seen_reccall
        else
            (
                AtTailAfter = not_at_tail_seen_reccall
            ;
                (
                    AtTailAfter = not_at_tail_have_not_seen_reccall
                ;
                    % This might happen if one of the other tests above fails.
                    % If so, a warning may be useful.
                    AtTailAfter = at_tail(_)
                ),
                maybe_warn_tailcalls(TCallInfo, CodeAddr, Context, !InBodyInfo)
            ),
            Stmt = Stmt0,
            AtTailBefore = not_at_tail_seen_reccall
        )
    else
        % Leave this call unchanged.
        Stmt = Stmt0,
        not_at_tail(AtTailAfter, AtTailBefore)
    ).

:- pred mark_tailcalls_in_cases(tailcall_info::in,
    at_tail::in, list(at_tail)::out,
    list(mlds_switch_case)::in, list(mlds_switch_case)::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_cases(_, _, [], [], [], !InBodyInfo).
mark_tailcalls_in_cases(TCallInfo, AtTailAfter, [AtTailBefore | AtTailBefores],
        [Case0 | Cases0], [Case | Cases], !InBodyInfo) :-
    mark_tailcalls_in_case(TCallInfo, AtTailAfter, AtTailBefore,
        Case0, Case, !InBodyInfo),
    mark_tailcalls_in_cases(TCallInfo, AtTailAfter, AtTailBefores,
        Cases0, Cases, !InBodyInfo).

:- pred mark_tailcalls_in_case(tailcall_info::in, at_tail::in, at_tail::out,
    mlds_switch_case::in, mlds_switch_case::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_case(TCallInfo, AtTailAfter, AtTailBefore,
        Case0, Case, !InBodyInfo) :-
    Case0 = mlds_switch_case(FirstCond, LaterConds, Statement0),
    mark_tailcalls_in_statement(TCallInfo, AtTailAfter, AtTailBefore,
        Statement0, Statement, !InBodyInfo),
    Case = mlds_switch_case(FirstCond, LaterConds, Statement).

:- pred mark_tailcalls_in_default(tailcall_info::in, at_tail::in, at_tail::out,
    mlds_switch_default::in, mlds_switch_default::out,
    tc_in_body_info::in, tc_in_body_info::out) is det.

mark_tailcalls_in_default(TCallInfo, AtTailAfter, AtTailBefore,
        Default0, Default, !InBodyInfo) :-
    (
        ( Default0 = default_is_unreachable
        ; Default0 = default_do_nothing
        ),
        AtTailBefore = AtTailAfter,
        Default = Default0
    ;
        Default0 = default_case(Statement0),
        mark_tailcalls_in_statement(TCallInfo, AtTailAfter, AtTailBefore,
            Statement0, Statement, !InBodyInfo),
        Default = default_case(Statement)
    ).

%-----------------------------------------------------------------------------%

:- pred maybe_warn_tailcalls(tailcall_info::in, mlds_code_addr::in,
    mlds_context::in, tc_in_body_info::in, tc_in_body_info::out) is det.

maybe_warn_tailcalls(TCallInfo, CodeAddr, Context, !InBodyInfo) :-
    WarnTailCalls = TCallInfo ^ tci_warn_tail_calls,
    MaybeRequireTailrecInfo = TCallInfo ^ tci_maybe_require_tailrec,
    ( if
        % Trivially reject the common case.
        WarnTailCalls = do_not_warn_tail_calls,
        MaybeRequireTailrecInfo = no
    then
        true
    else if
        require_complete_switch [WarnTailCalls]
        (
            WarnTailCalls = do_not_warn_tail_calls,

            % We always warn/error if the pragma says so.
            MaybeRequireTailrecInfo = yes(RequireTailrecInfo),
            RequireTailrecInfo = enable_tailrec_warnings(WarnOrError,
                TailrecType, _)
        ;
            WarnTailCalls = warn_tail_calls,

            % if warnings are enabled then we check the pragma.  We check
            % that it doesn't disable warnings and also determine whether
            % this should be a warning or error.
            require_complete_switch [MaybeRequireTailrecInfo]
            (
                MaybeRequireTailrecInfo = no,
                % Choose some defaults.
                WarnOrError = we_warning,
                TailrecType = require_any_tail_recursion
            ;
                MaybeRequireTailrecInfo = yes(RequireTailrecInfo),
                require_complete_switch [RequireTailrecInfo]
                (
                    RequireTailrecInfo =
                        enable_tailrec_warnings(WarnOrError, TailrecType, _)
                ;
                    RequireTailrecInfo = suppress_tailrec_warnings(_),
                    false
                )
            )
        ),
        require_complete_switch [TailrecType]
        (
            TailrecType = require_any_tail_recursion
        ;
            TailrecType = require_direct_tail_recursion
            % XXX: Currently this has no effect since all tailcalls on MLDS
            % are direct tail calls.
        )
    then
        (
            CodeAddr = code_addr_proc(QualProcLabel, _Sig)
        ;
            CodeAddr = code_addr_internal(QualProcLabel,
                _SeqNum, _Sig)
        ),
        QualProcLabel = qual(_, _, ProcLabel),
        ProcLabel = mlds_proc_label(PredLabel, ProcId),
        (
            PredLabel = mlds_special_pred_label(_, _, _, _)
            % Don't warn about special preds.
        ;
            PredLabel = mlds_user_pred_label(PredOrFunc, _MaybeModule,
                Name, Arity, _CodeModel, _NonOutputFunc),
            SymName = unqualified(Name),
            SimpleCallId = simple_call_id(PredOrFunc, SymName, Arity),
            Specs0 = !.InBodyInfo ^ tibi_specs,
            add_message_for_nontail_recursive_call(SimpleCallId, ProcId,
                WarnOrError, mlds_get_prog_context(Context), Specs0, Specs),
            !InBodyInfo ^ tibi_specs := Specs
        )
    else
        true
    ).

%-----------------------------------------------------------------------------%

% match_return_vals(Rvals, Lvals):
% match_return_val(Rval, Lval):
%   Check that the Lval(s) returned by a call match
%   the Rval(s) in the `return' statement that follows,
%   and those Lvals are local variables
%   (so that assignments to them won't have any side effects),
%   so that we can optimize the call into a tailcall.

:- pred match_return_vals(list(mlds_rval)::in, list(mlds_lval)::in) is semidet.

match_return_vals([], []).
match_return_vals([Rval | Rvals], [Lval | Lvals]) :-
    match_return_val(Rval, Lval),
    match_return_vals(Rvals, Lvals).

:- pred match_return_val(mlds_rval::in, mlds_lval::in) is semidet.

match_return_val(ml_lval(Lval), Lval) :-
    lval_is_local(Lval) = is_local.

:- type is_local
    --->    is_local
    ;       is_not_local.

:- func lval_is_local(mlds_lval) = is_local.

lval_is_local(Lval) = IsLocal :-
    (
        Lval = ml_var(_, _),
        % We just assume it is local. (This assumption is true for the code
        % generated by ml_code_gen.m.)
        IsLocal = is_local
    ;
        Lval = ml_field(_Tag, Rval, _Field, _, _),
        % A field of a local variable is local.
        ( if Rval = ml_mem_addr(BaseLval) then
            IsLocal = lval_is_local(BaseLval)
        else
            IsLocal = is_not_local
        )
    ;
        ( Lval = ml_mem_ref(_Rval, _Type)
        ; Lval = ml_global_var_ref(_)
        ),
        IsLocal = is_not_local
    ).

%-----------------------------------------------------------------------------%

:- type may_yield_dangling_stack_ref
    --->    may_yield_dangling_stack_ref
    ;       will_not_yield_dangling_stack_ref.

% check_rvals:
% check_maybe_rval:
% check_rval:
%   Find out if the specified rval(s) might evaluate to the addresses of
%   local variables (or fields of local variables) or nested functions.

:- func check_rvals(list(mlds_rval), locals) = may_yield_dangling_stack_ref.

check_rvals([], _) = will_not_yield_dangling_stack_ref.
check_rvals([Rval | Rvals], Locals) = MayYieldDanglingStackRef :-
    ( if check_rval(Rval, Locals) = may_yield_dangling_stack_ref then
        MayYieldDanglingStackRef = may_yield_dangling_stack_ref
    else
        MayYieldDanglingStackRef = check_rvals(Rvals, Locals)
    ).

:- func check_maybe_rval(maybe(mlds_rval), locals)
    = may_yield_dangling_stack_ref.

check_maybe_rval(no, _) = will_not_yield_dangling_stack_ref.
check_maybe_rval(yes(Rval), Locals) = check_rval(Rval, Locals).

:- func check_rval(mlds_rval, locals) = may_yield_dangling_stack_ref.

check_rval(Rval, Locals) = MayYieldDanglingStackRef :-
    (
        Rval = ml_lval(_Lval),
        % Passing the _value_ of an lval is fine.
        MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
    ;
        Rval = ml_mkword(_Tag, SubRval),
        MayYieldDanglingStackRef = check_rval(SubRval, Locals)
    ;
        Rval = ml_const(Const),
        MayYieldDanglingStackRef = check_const(Const, Locals)
    ;
        Rval = ml_unop(_Op, XRval),
        MayYieldDanglingStackRef = check_rval(XRval, Locals)
    ;
        Rval = ml_binop(_Op, XRval, YRval),
        ( if check_rval(XRval, Locals) = may_yield_dangling_stack_ref then
            MayYieldDanglingStackRef = may_yield_dangling_stack_ref
        else
            MayYieldDanglingStackRef = check_rval(YRval, Locals)
        )
    ;
        Rval = ml_mem_addr(Lval),
        % Passing the address of an lval is a problem,
        % if that lval names a local variable.
        MayYieldDanglingStackRef = check_lval(Lval, Locals)
    ;
        Rval = ml_vector_common_row(_VectorCommon, RowRval),
        MayYieldDanglingStackRef = check_rval(RowRval, Locals)
    ;
        ( Rval = ml_scalar_common(_)
        ; Rval = ml_self(_)
        ),
        MayYieldDanglingStackRef = may_yield_dangling_stack_ref
    ).

    % Find out if the specified lval might be a local variable
    % (or a field of a local variable).
    %
:- func check_lval(mlds_lval, locals) = may_yield_dangling_stack_ref.

check_lval(Lval, Locals) = MayYieldDanglingStackRef :-
    (
        Lval = ml_var(Var0, _),
        ( if var_is_local(Var0, Locals) then
            MayYieldDanglingStackRef = may_yield_dangling_stack_ref
        else
            MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
        )
    ;
        Lval = ml_field(_MaybeTag, Rval, _FieldId, _, _),
        MayYieldDanglingStackRef = check_rval(Rval, Locals)
    ;
        ( Lval = ml_mem_ref(_, _)
        ; Lval = ml_global_var_ref(_)
        ),
        % We assume that the addresses of local variables are only ever
        % passed down to other functions, or assigned to, so a mem_ref lval
        % can never refer to a local variable.
        MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
    ).

    % Find out if the specified const might be the address of a local variable
    % or nested function.
    %
    % The addresses of local variables are probably not consts, at least
    % not unless those variables are declared as static (i.e. `one_copy'),
    % so it might be safe to allow all data_addr_consts here, but currently
    % we just take a conservative approach.
    %
:- func check_const(mlds_rval_const, locals) = may_yield_dangling_stack_ref.

check_const(Const, Locals) = MayYieldDanglingStackRef :-
    (
        Const = mlconst_code_addr(CodeAddr),
        ( if function_is_local(CodeAddr, Locals) then
            MayYieldDanglingStackRef = may_yield_dangling_stack_ref
        else
            MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
        )
    ;
        Const = mlconst_data_addr(DataAddr),
        DataAddr = data_addr(ModuleName, DataName),
        ( if DataName = mlds_data_var(VarName) then
            ( if
                var_is_local(qual(ModuleName, module_qual, VarName), Locals)
            then
                MayYieldDanglingStackRef = may_yield_dangling_stack_ref
            else
                MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
            )
        else
            MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
        )
    ;
        ( Const = mlconst_true
        ; Const = mlconst_false
        ; Const = mlconst_int(_)
        ; Const = mlconst_uint(_)
        ; Const = mlconst_enum(_, _)
        ; Const = mlconst_char(_)
        ; Const = mlconst_foreign(_, _, _)
        ; Const = mlconst_float(_)
        ; Const = mlconst_string(_)
        ; Const = mlconst_multi_string(_)
        ; Const = mlconst_named_const(_)
        ; Const = mlconst_null(_)
        ),
        MayYieldDanglingStackRef = will_not_yield_dangling_stack_ref
    ).

    % Check whether the specified variable is defined locally, i.e. in storage
    % that might no longer exist when the function returns or does a tail call.
    %
    % It would be safe to fail for variables declared static (i.e. `one_copy'),
    % but currently we just take a conservative approach.
    %
:- pred var_is_local(mlds_var::in, locals::in) is semidet.

var_is_local(Var, Locals) :-
    % XXX we ignore the ModuleName -- that is safe, but overly conservative.
    Var = qual(_ModuleName, _QualKind, VarName),
    some [Local] (
        locals_member(Local, Locals),
        Local = entity_data(mlds_data_var(VarName))
    ).

    % Check whether the specified function is defined locally (i.e. as a
    % nested function).
    %
:- pred function_is_local(mlds_code_addr::in, locals::in) is semidet.

function_is_local(CodeAddr, Locals) :-
    (
        CodeAddr = code_addr_proc(QualifiedProcLabel, _Sig),
        MaybeSeqNum = no
    ;
        CodeAddr = code_addr_internal(QualifiedProcLabel, SeqNum, _Sig),
        MaybeSeqNum = yes(SeqNum)
    ),
    % XXX we ignore the ModuleName -- that is safe, but might be
    % overly conservative.
    QualifiedProcLabel = qual(_ModuleName, _QualKind, ProcLabel),
    ProcLabel = mlds_proc_label(PredLabel, ProcId),
    some [Local] (
        locals_member(Local, Locals),
        Local = entity_function(PredLabel, ProcId, MaybeSeqNum, _PredId)
    ).

    % locals_member(Name, Locals):
    %
    % Nondeterministically enumerates the names of all the entities in Locals.
    %
:- pred locals_member(mlds_entity_name::out, locals::in) is nondet.

locals_member(Name, LocalsList) :-
    list.member(Locals, LocalsList),
    (
        Locals = local_defns(Defns),
        list.member(Defn, Defns),
        Defn = mlds_defn(Name, _, _, _)
    ;
        Locals = local_params(Params),
        list.member(Param, Params),
        Param = mlds_argument(Name, _, _)
    ).

%-----------------------------------------------------------------------------%
:- end_module ml_backend.ml_tailcall.
%-----------------------------------------------------------------------------%
