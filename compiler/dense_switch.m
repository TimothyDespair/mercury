%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1994-2007, 2009-2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: dense_switch.m.
% Author: fjh.
%
% For switches on atomic types, generate code using a dense jump table.
%
%-----------------------------------------------------------------------------%

:- module ll_backend.dense_switch.
:- interface.

:- import_module hlds.code_model.
:- import_module hlds.hlds_goal.
:- import_module ll_backend.code_info.
:- import_module ll_backend.llds.
:- import_module parse_tree.prog_data.

:- import_module list.

%-----------------------------------------------------------------------------%

:- type dense_switch_info.

    % Should this switch be implemented as a dense jump table?
    % If so, we return the starting and ending values for the table,
    % and whether the switch is not covers all cases or not
    % (we may convert locally semidet switches into locally det
    % switches by adding extra cases whose body is just `fail').
    %
:- pred tagged_case_list_is_dense_switch(code_info::in, mer_type::in,
    list(tagged_case)::in, int::in, int::in, int::in, int::in,
    can_fail::in, dense_switch_info::out) is semidet.

    % Generate code for a switch using a dense jump table.
    %
:- pred generate_dense_switch(list(tagged_case)::in, rval::in, string::in,
    code_model::in, hlds_goal_info::in,  dense_switch_info::in,
    label::in, branch_end::in, branch_end::out, llds_code::out,
    code_info::in, code_info::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.builtin_ops.
:- import_module backend_libs.switch_util.
:- import_module check_hlds.type_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_llds.
:- import_module hlds.hlds_out.
:- import_module hlds.hlds_out.hlds_out_goal.
:- import_module ll_backend.code_gen.
:- import_module ll_backend.trace_gen.

:- import_module assoc_list.
:- import_module cord.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module svmap.

%-----------------------------------------------------------------------------%

:- type dense_switch_info
    --->    dense_switch_info(
                first_value     :: int,
                last_value      :: int,
                new_can_fail    :: can_fail
            ).

tagged_case_list_is_dense_switch(CI, VarType, TaggedCases,
        LowerLimit, UpperLimit, NumValues, ReqDensity, CanFail0,
        DenseSwitchInfo) :-
    list.length(TaggedCases, NumCases),
    NumCases > 2,

    Span = UpperLimit - LowerLimit,
    Range = Span + 1,
    Density = switch_density(NumValues, Range),
    Density > ReqDensity,
    (
        CanFail0 = can_fail,
        % For semidet switches, we normally need to check that the variable
        % is in range before we index into the jump table. However, if the
        % range of the type is sufficiently small, we can make the jump table
        % large enough to hold all of the values for the type.
        get_module_info(CI, ModuleInfo),
        classify_type(ModuleInfo, VarType) = TypeCategory,
        (
            type_range(ModuleInfo, TypeCategory, VarType, _Min, _Max,
                TypeRange),
            DetDensity = switch_density(NumValues, TypeRange),
            DetDensity > ReqDensity
        ->
            CanFail = cannot_fail,
            FirstVal = 0,
            LastVal = TypeRange - 1
        ;
            CanFail = CanFail0,
            FirstVal = LowerLimit,
            LastVal = UpperLimit
        )
    ;
        CanFail0 = cannot_fail,
        CanFail = cannot_fail,
        FirstVal = LowerLimit,
        LastVal = UpperLimit
    ),
    DenseSwitchInfo = dense_switch_info(FirstVal, LastVal, CanFail).

%---------------------------------------------------------------------------%

generate_dense_switch(TaggedCases, VarRval, VarName, CodeModel, SwitchGoalInfo,
        DenseSwitchInfo, EndLabel, MaybeEnd0, MaybeEnd, Code, !CI) :-
    % Evaluate the variable which we are going to be switching on.
    % If the case values start at some number other than 0,
    % then subtract that number to give us a zero-based index.
    DenseSwitchInfo = dense_switch_info(FirstVal, LastVal, CanFail),
    ( FirstVal = 0 ->
        IndexRval = VarRval
    ;
        IndexRval = binop(int_sub, VarRval, const(llconst_int(FirstVal)))
    ),
    % If the switch is not locally deterministic, we need to check that
    % the value of the variable lies within the appropriate range.
    (
        CanFail = can_fail,
        Difference = LastVal - FirstVal,
        fail_if_rval_is_false(
            binop(unsigned_le, IndexRval, const(llconst_int(Difference))),
            RangeCheckCode, !CI)
    ;
        CanFail = cannot_fail,
        RangeCheckCode = empty
    ),

    % Generate the cases.
    % We keep track of the code_info at the end of the non-fail cases.
    % We have to do this because generating a `fail' slot last would yield
    % the wrong liveness and would not unset the failure continuation
    % for a nondet switch.
    list.map_foldl3(generate_dense_case(VarName, CodeModel, SwitchGoalInfo,
        EndLabel), TaggedCases, CasesCodes,
        map.init, IndexMap, MaybeEnd0, MaybeEnd, !CI),
    CasesCode = cord_list_to_cord(CasesCodes),

    % Generate the jump table.
    map.to_assoc_list(IndexMap, IndexPairs),
    generate_dense_jump_table(FirstVal, LastVal, IndexPairs, Targets,
        no, MaybeFailLabel, !CI),
    JumpCode = singleton(
        llds_instr(computed_goto(IndexRval, Targets),
            "switch (using dense jump table)")
    ),

    % If there is no case for any index value in range, generate the failure
    % code we execute for such cases.
    (
        MaybeFailLabel = no,
        FailCode = empty
    ;
        MaybeFailLabel = yes(FailLabel),
        FailComment = "compiler-introduced `fail' case of dense switch",
        FailLabelCode = singleton(
            llds_instr(label(FailLabel), FailComment)
        ),
        generate_failure(FailureCode, !CI),
        FailCode = FailLabelCode ++ FailureCode
    ),

    EndLabelCode = singleton(
        llds_instr(label(EndLabel), "end of dense switch")
    ),

    % Assemble the code fragments.
    Code = RangeCheckCode ++ JumpCode ++ CasesCode ++ FailCode ++ EndLabelCode.

%---------------------------------------------------------------------------%

:- pred generate_dense_case(string::in, code_model::in, hlds_goal_info::in,
    label::in, tagged_case::in, llds_code::out,
    map(int, label)::in, map(int, label)::out,
    branch_end::in, branch_end::out,
    code_info::in, code_info::out) is det.

generate_dense_case(VarName, CodeModel, SwitchGoalInfo, EndLabel,
        TaggedCase, Code, !IndexMap, !MaybeEnd, !CI) :-
    TaggedCase = tagged_case(TaggedMainConsId, TaggedOtherConsIds, _, Goal),
    project_cons_name_and_tag(TaggedMainConsId, MainConsName, MainConsTag),
    list.map2(project_cons_name_and_tag, TaggedOtherConsIds,
        OtherConsNames, OtherConsTags),
    LabelComment = case_comment(VarName, MainConsName, OtherConsNames),
    get_next_label(Label, !CI),
    record_dense_label_for_cons_tag(Label, MainConsTag, !IndexMap),
    list.foldl(record_dense_label_for_cons_tag(Label), OtherConsTags,
        !IndexMap),
    LabelCode = singleton(
        llds_instr(label(Label), LabelComment)
    ),
    % We need to save the expression cache, etc.,
    % and restore them when we've finished.
    remember_position(!.CI, BranchStart),
    maybe_generate_internal_event_code(Goal, SwitchGoalInfo, TraceCode, !CI),
    code_gen.generate_goal(CodeModel, Goal, GoalCode, !CI),
    BranchToEndCode = singleton(
        llds_instr(goto(code_label(EndLabel)),
            "branch to end of dense switch")
    ),
    goal_info_get_store_map(SwitchGoalInfo, StoreMap),
    generate_branch_end(StoreMap, !MaybeEnd, SaveCode, !CI),
    Code = LabelCode ++ TraceCode ++ GoalCode ++ SaveCode ++ BranchToEndCode,
    reset_to_position(BranchStart, !CI).

:- pred record_dense_label_for_cons_tag(label::in, cons_tag::in,
    map(int, label)::in, map(int, label)::out) is det.

record_dense_label_for_cons_tag(Label, ConsTag, !IndexMap) :-
    ( ConsTag = int_tag(Index) ->
        svmap.det_insert(Index, Label, !IndexMap)
    ;
        unexpected(this_file, "record_label_for_index: not int_tag")
    ).

%----------------------------------------------------------------------------%

:- pred generate_dense_jump_table(int::in, int::in,
    assoc_list(int, label)::in, list(maybe(label))::out,
    maybe(label)::in, maybe(label)::out,
    code_info::in, code_info::out) is det.

generate_dense_jump_table(CurVal, LastVal, IndexPairs, Targets,
        !MaybeFailLabel, !CI) :-
    ( CurVal > LastVal ->
        expect(unify(IndexPairs, []), this_file,
            "generate_dense_jump_table: NextVal > LastVal, IndexList not []"),
        Targets = []
    ;
        NextVal = CurVal + 1,
        (
            IndexPairs = [],
            get_dense_fail_label(FailLabel, !MaybeFailLabel, !CI),
            generate_dense_jump_table(NextVal, LastVal, IndexPairs,
                LaterTargets, !MaybeFailLabel, !CI),
            Targets = [yes(FailLabel) | LaterTargets]
        ;
            IndexPairs = [FirstIndexPair | LaterIndexPairs],
            FirstIndexPair = FirstIndex - FirstLabel,
            ( FirstIndex = CurVal ->
                generate_dense_jump_table(NextVal, LastVal, LaterIndexPairs,
                    LaterTargets, !MaybeFailLabel, !CI),
                Targets = [yes(FirstLabel) | LaterTargets]
            ;
                get_dense_fail_label(FailLabel, !MaybeFailLabel, !CI),
                generate_dense_jump_table(NextVal, LastVal, IndexPairs,
                    LaterTargets, !MaybeFailLabel, !CI),
                Targets = [yes(FailLabel) | LaterTargets]
            )
        )
    ).

:- pred get_dense_fail_label(label::out, maybe(label)::in, maybe(label)::out,
    code_info::in, code_info::out) is det.

get_dense_fail_label(FailLabel, !MaybeFailLabel, !CI) :-
    (
        !.MaybeFailLabel = no,
        get_next_label(FailLabel, !CI),
        !:MaybeFailLabel = yes(FailLabel)
    ;
        !.MaybeFailLabel = yes(FailLabel)
    ).

%---------------------------------------------------------------------------%

:- func this_file = string.

this_file = "dense_switch.m".

%----------------------------------------------------------------------------%
:- end_module dense_switch.
%----------------------------------------------------------------------------%
