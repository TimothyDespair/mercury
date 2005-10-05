%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2001-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% rtti_to_mlds.m: convert RTTI data structures to MLDS.
% Authors: fjh, zs
%
% This module defines routines to convert from the back-end-independent
% RTTI data structures into MLDS definitions.
% The RTTI data structures are used for static data that is used
% for handling RTTI, polymorphism, and typeclasses.
%
% XXX There are problems with these definitions for the Java back-end.
% Under the current system, the definitions are output as static variables
% with static initializers, ordered so that subdefinitions always appear before
% the definition which uses them.  This is neccessary because in Java, static
% initializers are performed at runtime in textual order, and if a definition
% relies on another static variable for its constructor but said variable has
% not been initialized, then it is treated as `null' by the JVM with no
% warning.
% The problem with this approach is that it won't work for cyclic definitions.
% eg:
%   :- type foo ---> f(bar) ; g.
%   :- type bar ---> f2(foo) ; g2
% At some point this should be changed so that initialization is performed by 2
% phases: first allocate all of the objects, then fill in the fields.
%
% XXX In the absence of this fix, there are still several places in the code
% below which use list__append.  If possible these lists should instead be
% manipulated through some use of prepending and/or list__reverse instead, so
% that the algorithm stays O(N).
%
%-----------------------------------------------------------------------------%

:- module ml_backend__rtti_to_mlds.
:- interface.

:- import_module backend_libs__rtti.
:- import_module hlds__hlds_module.
:- import_module ml_backend__mlds.

:- import_module list.

    % Return a list of MLDS definitions for the given rtti_data list.
    %
:- func rtti_data_list_to_mlds(module_info, list(rtti_data)) = mlds__defns.

:- implementation.

:- import_module backend_libs__foreign.
:- import_module backend_libs__pseudo_type_info.
:- import_module backend_libs__type_ctor_info.
:- import_module check_hlds__type_util.
:- import_module hlds__code_model.
:- import_module hlds__hlds_data.
:- import_module hlds__hlds_pred.
:- import_module mdbcomp__prim_data.
:- import_module ml_backend__ml_closure_gen.
:- import_module ml_backend__ml_code_util.
:- import_module ml_backend__ml_unify_gen.
:- import_module parse_tree__error_util.
:- import_module parse_tree__prog_data.
:- import_module parse_tree__prog_out.
:- import_module parse_tree__prog_util.

:- import_module assoc_list.
:- import_module bool.
:- import_module counter.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module require.
:- import_module std_util.
:- import_module string.
:- import_module term.

rtti_data_list_to_mlds(ModuleInfo, RttiDatas) = MLDS_Defns :-
    RealRttiDatas = list__filter(real_rtti_data, RttiDatas),
    MLDS_DefnLists0 = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    MLDS_Defns0 = list__condense(MLDS_DefnLists0),
    list__filter(mlds_defn_is_potentially_duplicated, MLDS_Defns0,
        MaybeDupDefns0, NoDupDefns),
    list__sort_and_remove_dups(MaybeDupDefns0, MaybeDupDefns),
    MLDS_Defns = list__append(MaybeDupDefns, NoDupDefns).

:- pred mlds_defn_is_potentially_duplicated(mlds__defn::in) is semidet.

mlds_defn_is_potentially_duplicated(MLDS_Defn) :-
    MLDS_Defn = mlds__defn(EntityName, _, _, _),
    EntityName = data(DataName),
    DataName = rtti(ctor_rtti_id(_, RttiName)),
    ( RttiName = type_info(_)
    ; RttiName = pseudo_type_info(_)
    ).

    % return a list of MLDS definitions for the given rtti_data.
:- func rtti_data_to_mlds(module_info, rtti_data) = mlds__defns.

rtti_data_to_mlds(ModuleInfo, RttiData) = MLDS_Defns :-
    ( RttiData = pseudo_type_info(type_var(_)) ->
        % These just get represented as integers, so we don't need to define
        % a structure for them; which is why rtti_data_to_name/3 does not
        % handle this case.
        MLDS_Defns = []
    ;
        rtti_data_to_id(RttiData, RttiId),
        Name = data(rtti(RttiId)),
        gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo,
            Initializer, ExtraDefns),
        rtti_entity_name_and_init_to_defn(Name, RttiId, Initializer,
            MLDS_Defn),
        MLDS_Defns = list__append(ExtraDefns, [MLDS_Defn])
    ).

:- pred rtti_name_and_init_to_defn(rtti_type_ctor::in, ctor_rtti_name::in,
    mlds__initializer::in, mlds__defn::out) is det.

rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Initializer, MLDS_Defn) :-
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    rtti_id_and_init_to_defn(RttiId, Initializer, MLDS_Defn).

:- pred rtti_id_and_init_to_defn(rtti_id::in, mlds__initializer::in,
    mlds__defn::out) is det.

rtti_id_and_init_to_defn(RttiId, Initializer, MLDS_Defn) :-
    Name = data(rtti(RttiId)),
    rtti_entity_name_and_init_to_defn(Name, RttiId, Initializer, MLDS_Defn).

:- pred rtti_entity_name_and_init_to_defn(mlds__entity_name::in, rtti_id::in,
    mlds__initializer::in, mlds__defn::out) is det.

rtti_entity_name_and_init_to_defn(Name, RttiId, Initializer, MLDS_Defn) :-
    % Generate the context.
    %
    % XXX The rtti_data ought to include a prog_context (the context of the
    % corresponding type or instance definition)
    term__context_init(Context),
    MLDS_Context = mlds__make_context(Context),

    % Generate the declaration flags.
    Exported = rtti_id_is_exported(RttiId),
    Flags = rtti_data_decl_flags(Exported),

    % The GC never needs to trace these definitions, because they are static
    % constants, and can point only to other static constants, not to the heap.
    GC_TraceCode = no,

    % Generate the declaration body, i.e. the type and the initializer
    MLDS_Type = rtti_type(item_type(RttiId)),
    DefnBody = mlds__data(MLDS_Type, Initializer, GC_TraceCode),
    MLDS_Defn = mlds__defn(Name, MLDS_Context, Flags, DefnBody).

    % Return the declaration flags appropriate for an rtti_data.
    % Note that this must be the same as ml_static_const_decl_flags,
    % except for the access, so that ml_decl_is_static_const works.
    %
:- func rtti_data_decl_flags(bool) = mlds__decl_flags.

rtti_data_decl_flags(Exported) = MLDS_DeclFlags :-
    (
        Exported = yes,
        Access = public
    ;
        Exported = no,
        Access = private
    ),
    PerInstance = one_copy,
    Virtuality = non_virtual,
    Finality = final,
    Constness = const,
    Abstractness = concrete,
    MLDS_DeclFlags = init_decl_flags(Access, PerInstance,
        Virtuality, Finality, Constness, Abstractness).

%-----------------------------------------------------------------------------%

    % Return an MLDS initializer for the given RTTI definition
    % occurring in the given module.
    %
:- pred gen_init_rtti_data_defn(rtti_data::in, rtti_id::in, module_info::in,
    mlds__initializer::out, list(mlds__defn)::out) is det.

gen_init_rtti_data_defn(RttiData, _RttiId, ModuleInfo, Init, ExtraDefns) :-
    RttiData = base_typeclass_info(_InstanceModule, _ClassId, _InstanceStr,
        BaseTypeClassInfo),
    BaseTypeClassInfo = base_typeclass_info(N1, N2, N3, N4, N5, Methods),
    NumExtra = BaseTypeClassInfo ^ num_extra,
    list__map_foldl(gen_init_method(ModuleInfo, NumExtra),
        Methods, MethodInitializers, [], ExtraDefns),
    Init = init_array([
        gen_init_boxed_int(N1),
        gen_init_boxed_int(N2),
        gen_init_boxed_int(N3),
        gen_init_boxed_int(N4),
        gen_init_boxed_int(N5)
        | MethodInitializers
    ]).
gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = type_info(TypeInfo),
    gen_type_info_defn(ModuleInfo, TypeInfo, RttiId, Init, SubDefns).
gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = pseudo_type_info(PseudoTypeInfo),
    gen_pseudo_type_info_defn(ModuleInfo, PseudoTypeInfo, RttiId,
        Init, SubDefns).
gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = type_class_decl(TCDecl),
    gen_type_class_decl_defn(TCDecl, RttiId, ModuleInfo, Init, SubDefns).
gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = type_class_instance(Instance),
    gen_type_class_instance_defn(Instance, RttiId, ModuleInfo, Init, SubDefns).
gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = type_ctor_info(TypeCtorData),
    TypeCtorData = type_ctor_data(Version, TypeModule, TypeName,
        TypeArity, UnifyUniv, CompareUniv, Flags, TypeCtorDetails),
    RttiTypeCtor = rtti_type_ctor(TypeModule, TypeName, TypeArity),
    mdbcomp__prim_data__sym_name_to_string(TypeModule, TypeModuleName),
    NumPtags = type_ctor_details_num_ptags(TypeCtorDetails),
    NumFunctors = type_ctor_details_num_functors(TypeCtorDetails),
    FunctorsRttiId = ctor_rtti_id(RttiTypeCtor, type_functors),
    LayoutRttiId = ctor_rtti_id(RttiTypeCtor, type_layout),

    some [!Defns] (
        gen_functors_layout_info(ModuleInfo, RttiTypeCtor,
            TypeCtorDetails, FunctorsInfo, LayoutInfo, !:Defns),

        % Note that gen_init_special_pred will by necessity add an extra level
        % of indirection to calling the special preds. However the backend
        % compiler should be smart enough to ensure that this is inlined away.
        %
        gen_init_special_pred(ModuleInfo, UnifyUniv, UnifyInit, !Defns),
        gen_init_special_pred(ModuleInfo, CompareUniv, CompareInit, !Defns),

        SubDefns = !.Defns
    ),

    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_int(TypeArity),
        gen_init_int(Version),
        gen_init_int(NumPtags),
        gen_init_type_ctor_rep(TypeCtorData),
        UnifyInit,
        CompareInit,
        gen_init_string(TypeModuleName),
        gen_init_string(TypeName),
        % In the C back-end, these two "structs" are actually unions.
        % We need to use `init_struct' here so that the initializers
        % get enclosed in curly braces.
        init_struct(mlds__rtti_type(item_type(FunctorsRttiId)), [
            FunctorsInfo
        ]),
        init_struct(mlds__rtti_type(item_type(LayoutRttiId)), [
            LayoutInfo
        ]),
        gen_init_int(NumFunctors),
        gen_init_int(encode_type_ctor_flags(Flags))
        % These two are commented out while the corresponding fields of the
        % MR_TypeCtorInfo_Struct type are commented out.
        % gen_init_maybe(gen_init_rtti_name(RttiTypeCtor), MaybeHashCons),
        % XXX this may need to change to call
        % gen_init_special_pred, if this is re-enabled.
        % gen_init_proc_id_from_univ(ModuleInfo, PrettyprinterProc)
    ]).

gen_init_rtti_data_defn(RttiData, RttiId, ModuleInfo, Init, SubDefns) :-
    RttiData = aditi_proc_info(ProcLabel, InputTypeInfo, OutputTypeInfo),
    ( real_rtti_data(type_info(InputTypeInfo)) ->
        InputTypeInfoDefns = rtti_data_to_mlds(ModuleInfo,
            type_info(InputTypeInfo))
    ;
        InputTypeInfoDefns = []
    ),
    ( real_rtti_data(type_info(OutputTypeInfo)) ->
        OutputTypeInfoDefns = rtti_data_to_mlds(ModuleInfo,
            type_info(OutputTypeInfo))
    ;
        OutputTypeInfoDefns = []
    ),
    prog_out__sym_name_and_arity_to_string(
        qualified(ProcLabel ^ proc_module, ProcLabel ^ proc_name)/
            ProcLabel ^ proc_arity,
        ProcNameStr),
    module_info_get_name(ModuleInfo, ModuleName),
            
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_proc_id(ModuleInfo, ProcLabel),
        gen_init_string(ProcNameStr),
        gen_init_cast_rtti_data(mlds__type_info_type,
            ModuleName, type_info(InputTypeInfo)),
        gen_init_cast_rtti_data(mlds__type_info_type,
            ModuleName, type_info(OutputTypeInfo)),
        gen_init_int(code_model__represent_determinism(
            ProcLabel ^ proc_interface_detism))
    ]),
    SubDefns = InputTypeInfoDefns ++ OutputTypeInfoDefns.

%-----------------------------------------------------------------------------%

:- pred gen_type_class_decl_defn(tc_decl::in, rtti_id::in, module_info::in,
    mlds__initializer::out, list(mlds__defn)::out) is det.

gen_type_class_decl_defn(TCDecl, RttiId, ModuleInfo, Init, SubDefns) :-
    TCDecl = tc_decl(TCId, Version, Supers),
    TCId = tc_id(TCName, TVarNames, MethodIds),
    TCName = tc_name(ModuleSymName, ClassName, Arity),
    module_info_get_name(ModuleInfo, ModuleName),
    TVarNamesRttiId = tc_rtti_id(TCName, type_class_id_var_names),
    (
        TVarNames = [],
        TVarNameDefns = [],
        TVarNamesInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(TVarNamesRttiId)))
    ;
        TVarNames = [_ | _],
        gen_tc_id_var_names(TVarNamesRttiId, TVarNames, TVarNameDefn),
        TVarNameDefns = [TVarNameDefn],
        TVarNamesInit = gen_init_rtti_id(ModuleName, TVarNamesRttiId)
    ),
    MethodIdsRttiId = tc_rtti_id(TCName, type_class_id_method_ids),
    (
        MethodIds = [],
        MethodIdDefns = [],
        MethodIdsInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(MethodIdsRttiId)))
    ;
        MethodIds = [_ | _],
        gen_tc_id_method_ids(MethodIdsRttiId, TCName, MethodIds, MethodIdDefn),
        MethodIdDefns = [MethodIdDefn],
        MethodIdsInit = gen_init_rtti_id(ModuleName, MethodIdsRttiId)
    ),
    TCIdRttiId = tc_rtti_id(TCName, type_class_id),
    sym_name_to_string(ModuleSymName, ModuleSymNameStr),
    list__length(TVarNames, NumTVars),
    list__length(MethodIds, NumMethods),
    TCIdInit = init_struct(mlds__rtti_type(item_type(TCIdRttiId)), [
        gen_init_string(ModuleSymNameStr),
        gen_init_string(ClassName),
        gen_init_int(Arity),
        gen_init_int(NumTVars),
        gen_init_int(NumMethods),
        TVarNamesInit,
        MethodIdsInit
    ]),
    rtti_id_and_init_to_defn(TCIdRttiId, TCIdInit, TCIdDefn),
    (
        Supers = [],
        SuperDefns = [],
        SupersInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(MethodIdsRttiId)))
    ;
        Supers = [_ | _],
        list__map_foldl2(gen_tc_constraint(ModuleInfo,
            make_decl_super_id(TCName)), Supers, SuperRttiIds,
            counter__init(1), _, [], SuperConstrDefns),
        SuperArrayRttiName = type_class_decl_supers,
        SuperArrayRttiId = tc_rtti_id(TCName, SuperArrayRttiName),
        ElementType = mlds__rtti_type(element_type(SuperArrayRttiId)),
        SuperArrayInit = gen_init_array(
            gen_init_cast_rtti_id(ElementType, ModuleName), SuperRttiIds),
        rtti_id_and_init_to_defn(SuperArrayRttiId, SuperArrayInit, SuperDefn),
        list__append(SuperConstrDefns, [SuperDefn], SuperDefns),
        SupersInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(MethodIdsRttiId)))
    ),
    list__length(Supers, NumSupers),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_id(ModuleName, TCIdRttiId),
        gen_init_int(Version),
        gen_init_int(NumSupers),
        SupersInit
    ]),
    list__condense([TVarNameDefns, MethodIdDefns, [TCIdDefn], SuperDefns],
        SubDefns).

:- pred make_decl_super_id(tc_name::in, int::in, int::in, rtti_id::out)
    is det.

make_decl_super_id(TCName, TCNum, Arity, RttiId) :-
    TCRttiName = type_class_decl_super(TCNum, Arity),
    RttiId = tc_rtti_id(TCName, TCRttiName).

:- pred gen_tc_id_var_names(rtti_id::in, list(string)::in, mlds__defn::out)
    is det.

gen_tc_id_var_names(RttiId, Names, MLDS_Defn) :-
    Init = gen_init_array(gen_init_string, Names),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn).

:- pred gen_tc_id_method_ids(rtti_id::in, tc_name::in, list(tc_method_id)::in,
    mlds__defn::out) is det.

gen_tc_id_method_ids(RttiId, TCName, MethodIds, Defn) :-
    Init = gen_init_array(gen_tc_id_method_id(TCName), MethodIds),
    rtti_id_and_init_to_defn(RttiId, Init, Defn).

:- func gen_tc_id_method_id(tc_name, tc_method_id) = mlds__initializer.

gen_tc_id_method_id(TCName, MethodId) = Init :-
    MethodId = tc_method_id(MethodName, MethodArity, PredOrFunc),
    RttiId = tc_rtti_id(TCName, type_class_id_method_ids),
    Init = init_struct(mlds__rtti_type(element_type(RttiId)), [
        gen_init_string(MethodName),
        gen_init_int(MethodArity),
        gen_init_pred_or_func(PredOrFunc)
    ]).

%-----------------------------------------------------------------------------%

:- pred gen_type_class_instance_defn(tc_instance::in, rtti_id::in,
    module_info::in, mlds__initializer::out, list(mlds__defn)::out) is det.

gen_type_class_instance_defn(Instance, RttiId, ModuleInfo, Init, SubDefns) :-
    Instance = tc_instance(TCName, Types, NumTypeVars,
        InstanceConstraints, _Methods),
    TCDeclRttiId = tc_rtti_id(TCName, type_class_decl),
    list__length(InstanceConstraints, NumInstanceConstraints),
    InstanceTypesTCRttiName = type_class_instance_tc_type_vector(Types),
    InstanceTypesRttiId = tc_rtti_id(TCName, InstanceTypesTCRttiName),
    InstanceConstrsTCRttiName = type_class_instance_constraints(Types),
    InstanceConstrsRttiId = tc_rtti_id(TCName, InstanceConstrsTCRttiName),
    module_info_get_name(ModuleInfo, ModuleName),

    TypeRttiDatas = list__map(maybe_pseudo_type_info_to_rtti_data, Types),
    gen_pseudo_type_info_array(ModuleInfo, TypeRttiDatas, TypesInit,
        TypesDefns),
    rtti_id_and_init_to_defn(InstanceTypesRttiId, TypesInit, TypesDefn),

    list__map_foldl2(gen_tc_constraint(ModuleInfo,
        make_instance_constr_id(TCName, Types)),
        InstanceConstraints, TCConstrIds, counter__init(1), _,
        [], TCConstrDefns),
    ElementType = mlds__rtti_type(element_type(InstanceConstrsRttiId)),
    InstanceConstrsInit = gen_init_array(
        gen_init_cast_rtti_id(ElementType, ModuleName), TCConstrIds),
    rtti_id_and_init_to_defn(InstanceConstrsRttiId, InstanceConstrsInit,
        InstanceConstrsDefn),

    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_id(ModuleName, TCDeclRttiId),
        gen_init_int(NumTypeVars),
        gen_init_int(NumInstanceConstraints),
        gen_init_rtti_id(ModuleName, InstanceTypesRttiId),
        gen_init_rtti_id(ModuleName, InstanceConstrsRttiId)
    ]),
    list__condense([TypesDefns, [TypesDefn], TCConstrDefns,
        [InstanceConstrsDefn]], SubDefns).

:- pred make_instance_constr_id(tc_name::in, list(tc_type)::in,
    int::in, int::in, rtti_id::out) is det.

make_instance_constr_id(TCName, Types, TCNum, Arity, RttiId) :-
    RttiName = type_class_instance_constraint(Types, TCNum, Arity),
    RttiId = tc_rtti_id(TCName, RttiName).

%-----------------------------------------------------------------------------%

:- pred gen_type_info_defn(module_info::in, rtti_type_info::in, rtti_id::in,
    mlds__initializer::out, list(mlds__defn)::out) is det.

gen_type_info_defn(_, plain_arity_zero_type_info(_), _, _, _) :-
    unexpected(this_file, "gen_type_info_defn: plain_arity_zero_type_info").
gen_type_info_defn(ModuleInfo, plain_type_info(RttiTypeCtor, ArgTypes),
        RttiId, Init, SubDefns) :-
    ArgRttiDatas = list__map(type_info_to_rtti_data, ArgTypes),
    RealRttiDatas = list__filter(real_rtti_data, ArgRttiDatas),
    SubDefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    SubDefns = list__condense(SubDefnLists),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_name(ModuleName, RttiTypeCtor, type_ctor_info),
        gen_init_cast_rtti_datas_array(mlds__type_info_type,
            ModuleName, ArgRttiDatas)
    ]).
gen_type_info_defn(ModuleInfo, var_arity_type_info(VarArityId, ArgTypes),
        RttiId, Init, SubDefns) :-
    ArgRttiDatas = list__map(type_info_to_rtti_data, ArgTypes),
    RealRttiDatas = list__filter(real_rtti_data, ArgRttiDatas),
    SubDefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    SubDefns = list__condense(SubDefnLists),
    RttiTypeCtor = var_arity_id_to_rtti_type_ctor(VarArityId),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_name(ModuleName, RttiTypeCtor, type_ctor_info),
        gen_init_int(list__length(ArgTypes)),
        gen_init_cast_rtti_datas_array(mlds__type_info_type,
            ModuleName, ArgRttiDatas)
    ]).

:- pred gen_pseudo_type_info_defn(module_info::in, rtti_pseudo_type_info::in,
    rtti_id::in, mlds__initializer::out, list(mlds__defn)::out) is det.

gen_pseudo_type_info_defn(_, plain_arity_zero_pseudo_type_info(_), _, _, _) :-
    error("gen_pseudo_type_info_defn: plain_arity_zero_pseudo_type_info").
gen_pseudo_type_info_defn(ModuleInfo, PseudoTypeInfo, RttiId, Init,
        SubDefns) :-
    PseudoTypeInfo = plain_pseudo_type_info(RttiTypeCtor, ArgTypes),
    ArgRttiDatas = list__map(maybe_pseudo_type_info_to_rtti_data, ArgTypes),
    RealRttiDatas = list__filter(real_rtti_data, ArgRttiDatas),
    SubDefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    SubDefns = list__condense(SubDefnLists),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_name(ModuleName, RttiTypeCtor, type_ctor_info),
        gen_init_cast_rtti_datas_array(mlds__pseudo_type_info_type,
            ModuleName, ArgRttiDatas)
    ]).
gen_pseudo_type_info_defn(ModuleInfo, PseudoTypeInfo, RttiId, Init,
        SubDefns) :-
    PseudoTypeInfo = var_arity_pseudo_type_info(VarArityId, ArgTypes),
    ArgRttiDatas = list__map(maybe_pseudo_type_info_to_rtti_data, ArgTypes),
    RealRttiDatas = list__filter(real_rtti_data, ArgRttiDatas),
    SubDefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    SubDefns = list__condense(SubDefnLists),
    RttiTypeCtor = var_arity_id_to_rtti_type_ctor(VarArityId),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_rtti_name(ModuleName, RttiTypeCtor, type_ctor_info),
        gen_init_int(list__length(ArgTypes)),
        gen_init_cast_rtti_datas_array(mlds__pseudo_type_info_type,
            ModuleName, ArgRttiDatas)
    ]).
gen_pseudo_type_info_defn(_, type_var(_), _, _, _) :-
    unexpected(this_file, "gen_pseudo_type_info_defn: type_var").

%-----------------------------------------------------------------------------%

:- pred gen_functors_layout_info(module_info::in, rtti_type_ctor::in,
    type_ctor_details::in, mlds__initializer::out, mlds__initializer::out,
    list(mlds__defn)::out) is det.

gen_functors_layout_info(ModuleInfo, RttiTypeCtor, TypeCtorDetails,
        FunctorInit, LayoutInit, Defns) :-
    module_info_get_name(ModuleInfo, ModuleName),
    (
        TypeCtorDetails = enum(_, EnumFunctors, EnumByValue, EnumByName,
            _IsDummy),
        EnumFunctorDescs = list__map(
            gen_enum_functor_desc(ModuleInfo, RttiTypeCtor), EnumFunctors),
        ByValueDefn = gen_enum_value_ordered_table(ModuleInfo,
            RttiTypeCtor, EnumByValue),
        ByNameDefn = gen_enum_name_ordered_table(ModuleInfo,
            RttiTypeCtor, EnumByName),
        LayoutInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            enum_value_ordered_table),
        FunctorInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            enum_name_ordered_table),
        Defns = EnumFunctorDescs ++ [ByValueDefn, ByNameDefn]
    ;
        TypeCtorDetails = du(_, DuFunctors, DuByPtag, DuByName),
        DuFunctorDefnLists = list__map(
            gen_du_functor_desc(ModuleInfo, RttiTypeCtor), DuFunctors),
        DuFunctorDefns = list__condense(DuFunctorDefnLists),
        ByPtagDefns = gen_du_ptag_ordered_table(ModuleInfo,
            RttiTypeCtor, DuByPtag),
        ByNameDefn = gen_du_name_ordered_table(ModuleInfo,
            RttiTypeCtor, DuByName),
        LayoutInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            du_ptag_ordered_table),
        FunctorInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            du_name_ordered_table),
        Defns = DuFunctorDefns ++ [ByNameDefn | ByPtagDefns]
    ;
        TypeCtorDetails = reserved(_, MaybeResFunctors, ResFunctors,
            DuByPtag, MaybeResByName),
        MaybeResFunctorDefnLists = list__map(
            gen_maybe_res_functor_desc(ModuleInfo, RttiTypeCtor),
            MaybeResFunctors),
        MaybeResFunctorDefns = list__condense(MaybeResFunctorDefnLists),
        ByValueDefns = gen_maybe_res_value_ordered_table(ModuleInfo,
            RttiTypeCtor, ResFunctors, DuByPtag),
        ByNameDefn = gen_maybe_res_name_ordered_table(ModuleInfo,
            RttiTypeCtor, MaybeResByName),
        LayoutInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            res_value_ordered_table),
        FunctorInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            res_name_ordered_table),
        Defns = [ByNameDefn | ByValueDefns ++ MaybeResFunctorDefns]
    ;
        TypeCtorDetails = notag(_, NotagFunctor),
        Defns = gen_notag_functor_desc(ModuleInfo, RttiTypeCtor, NotagFunctor),
        LayoutInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            notag_functor_desc),
        FunctorInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            notag_functor_desc)
    ;
        TypeCtorDetails = eqv(EqvType),
        TypeRttiData = maybe_pseudo_type_info_to_rtti_data(EqvType),
        gen_pseudo_type_info(ModuleInfo, TypeRttiData, LayoutInit, Defns),
        % The type is a lie, but a safe one.
        FunctorInit = gen_init_null_pointer(mlds__generic_type)
    ;
        TypeCtorDetails = builtin(_),
        Defns = [],
        LayoutInit = gen_init_null_pointer(mlds__generic_type),
        FunctorInit = gen_init_null_pointer(mlds__generic_type)
    ;
        TypeCtorDetails = impl_artifact(_),
        Defns = [],
        LayoutInit = gen_init_null_pointer(mlds__generic_type),
        FunctorInit = gen_init_null_pointer(mlds__generic_type)
    ;
        TypeCtorDetails = foreign(_),
        Defns = [],
        LayoutInit = gen_init_null_pointer(mlds__generic_type),
        FunctorInit = gen_init_null_pointer(mlds__generic_type)
    ).

%-----------------------------------------------------------------------------%

:- func gen_enum_functor_desc(module_info, rtti_type_ctor, enum_functor)
    = mlds__defn.

gen_enum_functor_desc(_ModuleInfo, RttiTypeCtor, EnumFunctor) = MLDS_Defn :-
    EnumFunctor = enum_functor(FunctorName, Ordinal),
    RttiName = enum_functor_desc(Ordinal),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_string(FunctorName),
        gen_init_int(Ordinal)
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn).

:- func gen_notag_functor_desc(module_info, rtti_type_ctor, notag_functor)
    = list(mlds__defn).

gen_notag_functor_desc(ModuleInfo, RttiTypeCtor, NotagFunctorDesc)
        = MLDS_Defns :-
    NotagFunctorDesc = notag_functor(FunctorName, ArgType, MaybeArgName),
    ArgTypeRttiData = maybe_pseudo_type_info_to_rtti_data(ArgType),
    gen_pseudo_type_info(ModuleInfo, ArgTypeRttiData, PTIInit, SubDefns),
    RttiName = notag_functor_desc,
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_string(FunctorName),
        PTIInit,
        gen_init_maybe(ml_string_type, gen_init_string, MaybeArgName)
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn),
    MLDS_Defns = list__append(SubDefns, [MLDS_Defn]).

:- func gen_du_functor_desc(module_info, rtti_type_ctor, du_functor)
    = list(mlds__defn).

gen_du_functor_desc(ModuleInfo, RttiTypeCtor, DuFunctor) = MLDS_Defns :-
    DuFunctor = du_functor(FunctorName, Arity, Ordinal, Rep, ArgInfos,
        MaybeExistInfo),
    ArgTypes = list__map(du_arg_info_type, ArgInfos),
    MaybeArgNames = list__map(du_arg_info_name, ArgInfos),
    ArgNames = list__filter_map(project_yes, MaybeArgNames),
    ContainsVarBitVector = compute_contains_var_bit_vector(ArgTypes),
    module_info_get_name(ModuleInfo, ModuleName),
    (
        ArgInfos = [_ | _],
        ArgTypeDefns = gen_field_types(ModuleInfo, RttiTypeCtor,
            Ordinal, ArgTypes),
        ArgTypeInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            field_types(Ordinal))
    ;
        ArgInfos = [],
        ArgTypeDefns = [],
        ArgTypeInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(
                ctor_rtti_id(RttiTypeCtor, field_types(0)))))
    ),
    (
        ArgNames = [_ | _],
        ArgNameDefn = gen_field_names(ModuleInfo, RttiTypeCtor,
            Ordinal, MaybeArgNames),
        ArgNameDefns = [ArgNameDefn],
        ArgNameInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            field_names(Ordinal))
    ;
        ArgNames = [],
        ArgNameDefns = [],
        ArgNameInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(
                ctor_rtti_id(RttiTypeCtor, field_names(0)))))
    ),
    (
        MaybeExistInfo = yes(ExistInfo),
        ExistInfoDefns = gen_exist_info(ModuleInfo, RttiTypeCtor,
            Ordinal, ExistInfo),
        ExistInfoInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            exist_info(Ordinal))
    ;
        MaybeExistInfo = no,
        ExistInfoDefns = [],
        ExistInfoInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(
                ctor_rtti_id(RttiTypeCtor, exist_info(0)))))
    ),
    SubDefns = ArgTypeDefns ++ ArgNameDefns ++ ExistInfoDefns,
    (
        Rep = du_ll_rep(Ptag, SectagAndLocn)
    ;
        Rep = du_hl_rep(_),
        unexpected(this_file, "output_du_functor_defn: du_hl_rep")
    ),
    (
        SectagAndLocn = sectag_none,
        Locn = sectag_none,
        Stag = -1
    ;
        SectagAndLocn = sectag_local(Stag),
        Locn = sectag_local
    ;
        SectagAndLocn = sectag_remote(Stag),
        Locn = sectag_remote
    ),
    RttiName = du_functor_desc(Ordinal),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_string(FunctorName),
        gen_init_int(Arity),
        gen_init_int(ContainsVarBitVector),
        gen_init_sectag_locn(Locn),
        gen_init_int(Ptag),
        gen_init_int(Stag),
        gen_init_int(Ordinal),
        ArgTypeInit,
        ArgNameInit,
        ExistInfoInit
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn),
    MLDS_Defns = list__append(SubDefns, [MLDS_Defn]).

:- func gen_res_addr_functor_desc(module_info, rtti_type_ctor,
    reserved_functor) = mlds__defn.

gen_res_addr_functor_desc(ModuleInfo, RttiTypeCtor, ResFunctor) = MLDS_Defn :-
    ResFunctor = reserved_functor(FunctorName, Ordinal, ReservedAddress),
    RttiName = res_functor_desc(Ordinal),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_string(FunctorName),
        gen_init_int(Ordinal),
        gen_init_reserved_address(ModuleInfo, ReservedAddress)
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn).

:- func gen_maybe_res_functor_desc(module_info, rtti_type_ctor,
    maybe_reserved_functor) = list(mlds__defn).

gen_maybe_res_functor_desc(ModuleInfo, RttiTypeCtor, MaybeResFunctor)
        = MLDS_Defns :-
    (
        MaybeResFunctor = res_func(ResFunctor),
        MLDS_Defn = gen_res_addr_functor_desc(ModuleInfo, RttiTypeCtor,
            ResFunctor),
        MLDS_Defns = [MLDS_Defn]
    ;
        MaybeResFunctor = du_func(DuFunctor),
        MLDS_Defns = gen_du_functor_desc(ModuleInfo, RttiTypeCtor, DuFunctor)
    ).

%-----------------------------------------------------------------------------%

:- func gen_init_exist_locn(rtti_type_ctor, exist_typeinfo_locn) =
    mlds__initializer.

gen_init_exist_locn(RttiTypeCtor, ExistTypeInfoLocn) = Init :-
    (
        ExistTypeInfoLocn = typeinfo_in_tci(SlotInCell, SlotInTci)
    ;
        ExistTypeInfoLocn = plain_typeinfo(SlotInCell),
        SlotInTci = -1
    ),
    RttiId = ctor_rtti_id(RttiTypeCtor, exist_locn),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_int(SlotInCell),
        gen_init_int(SlotInTci)
    ]).

:- func gen_exist_locns_array(module_info, rtti_type_ctor, int,
    list(exist_typeinfo_locn)) = mlds__defn.

gen_exist_locns_array(_ModuleInfo, RttiTypeCtor, Ordinal, Locns) = MLDS_Defn :-
    Init = gen_init_array(gen_init_exist_locn(RttiTypeCtor), Locns),
    RttiName = exist_locns(Ordinal),
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- pred gen_tc_constraint(module_info::in,
    pred(int, int, rtti_id)::in(pred(in, in, out) is det),
    tc_constraint::in, rtti_id::out, counter::in, counter::out,
    list(mlds__defn)::in, list(mlds__defn)::out) is det.

gen_tc_constraint(ModuleInfo, MakeRttiId, Constraint, RttiId, !Counter,
        !Defns) :-
    Constraint = tc_constraint(TCName, Types),
    list__length(Types, Arity),
    counter__allocate(TCNum, !Counter),
    MakeRttiId(TCNum, Arity, RttiId),
    TCDeclRttiName = type_class_decl,
    module_info_get_name(ModuleInfo, ModuleName),
    TypeRttiDatas = list__map(maybe_pseudo_type_info_to_rtti_data, Types),
    gen_pseudo_type_info_array(ModuleInfo, TypeRttiDatas, PTIInits, PTIDefns),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_tc_rtti_name(ModuleName, TCName, TCDeclRttiName),
        PTIInits
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, ConstrDefn),
    list__append(PTIDefns, [ConstrDefn], NewDefns),
    list__append(!.Defns, NewDefns, !:Defns).

:- pred make_exist_tc_constr_id(rtti_type_ctor::in, int::in, int::in, int::in,
    rtti_id::out) is det.

make_exist_tc_constr_id(RttiTypeCtor, Ordinal, TCNum, Arity, RttiId) :-
    RttiName = exist_tc_constr(Ordinal, TCNum, Arity),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName).

:- func gen_exist_info(module_info, rtti_type_ctor, int, exist_info)
    = list(mlds__defn).

gen_exist_info(ModuleInfo, RttiTypeCtor, Ordinal, ExistInfo) = MLDS_Defns :-
    ExistInfo = exist_info(Plain, InTci, Constraints, Locns),
    module_info_get_name(ModuleInfo, ModuleName),
    RttiName = exist_info(Ordinal),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    list__length(Constraints, Tci),
    (
        Constraints = [],
        ConstrInit = gen_init_null_pointer(
            mlds__rtti_type(item_type(ctor_rtti_id(RttiTypeCtor,
                exist_tc_constrs(Ordinal))))),
        ConstrDefns = []
    ;
        Constraints = [_ | _],
        ConstrInit = gen_init_rtti_name(ModuleName, RttiTypeCtor,
            exist_tc_constrs(Ordinal)),
        list__map_foldl2(gen_tc_constraint(ModuleInfo,
            make_exist_tc_constr_id(RttiTypeCtor, Ordinal)),
            Constraints, TCConstrIds, counter__init(1), _,
            [], TCConstrDefns),
        TCConstrArrayRttiName = exist_tc_constrs(Ordinal),
        TCConstrArrayRttiId = ctor_rtti_id(RttiTypeCtor,
            TCConstrArrayRttiName),
        ElementType = mlds__rtti_type(element_type(TCConstrArrayRttiId)),
        TCConstrArrayInit = gen_init_array(
            gen_init_cast_rtti_id(ElementType, ModuleName), TCConstrIds),
        rtti_name_and_init_to_defn(RttiTypeCtor, TCConstrArrayRttiName,
            TCConstrArrayInit, TCConstrArrayDefn),
        list__append(TCConstrDefns, [TCConstrArrayDefn], ConstrDefns)
    ),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_int(Plain),
        gen_init_int(InTci),
        gen_init_int(Tci),
        gen_init_rtti_name(ModuleName, RttiTypeCtor, exist_locns(Ordinal)),
        ConstrInit
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn),
    LocnsDefn = gen_exist_locns_array(ModuleInfo, RttiTypeCtor, Ordinal,
        Locns),
    MLDS_Defns = [MLDS_Defn, LocnsDefn | ConstrDefns].

:- func gen_field_names(module_info, rtti_type_ctor, int, list(maybe(string)))
    = mlds__defn.

gen_field_names(_ModuleInfo, RttiTypeCtor, Ordinal, MaybeNames) = MLDS_Defn :-
    StrType = builtin(string),
    Init = gen_init_array(gen_init_maybe(
            mercury_type(StrType, str_type, non_foreign_type(StrType)),
            gen_init_string), MaybeNames),
    RttiName = field_names(Ordinal),
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_field_types(module_info, rtti_type_ctor, int,
    list(rtti_maybe_pseudo_type_info_or_self)) = list(mlds__defn).

gen_field_types(ModuleInfo, RttiTypeCtor, Ordinal, Types) = MLDS_Defns :-
    TypeRttiDatas = list__map(maybe_pseudo_type_info_or_self_to_rtti_data,
        Types),
    gen_pseudo_type_info_array(ModuleInfo, TypeRttiDatas, Init, SubDefns),
    RttiName = field_types(Ordinal),
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn),
    MLDS_Defns = list__append(SubDefns, [MLDS_Defn]).

%-----------------------------------------------------------------------------%

:- func gen_enum_value_ordered_table(module_info, rtti_type_ctor,
    map(int, enum_functor)) = mlds__defn.

gen_enum_value_ordered_table(ModuleInfo, RttiTypeCtor, EnumByValue)
        = MLDS_Defn :-
    map__values(EnumByValue, Functors),
    module_info_get_name(ModuleInfo, ModuleName),
    FunctorRttiNames = list__map(enum_functor_rtti_name, Functors),
    Init = gen_init_rtti_names_array(ModuleName, RttiTypeCtor,
        FunctorRttiNames),
    RttiName = enum_value_ordered_table,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_enum_name_ordered_table(module_info, rtti_type_ctor,
    map(string, enum_functor)) = mlds__defn.

gen_enum_name_ordered_table(ModuleInfo, RttiTypeCtor, EnumByName)
        = MLDS_Defn :-
    map__values(EnumByName, Functors),
    module_info_get_name(ModuleInfo, ModuleName),
    FunctorRttiNames = list__map(enum_functor_rtti_name, Functors),
    Init = gen_init_rtti_names_array(ModuleName, RttiTypeCtor,
        FunctorRttiNames),
    RttiName = enum_name_ordered_table,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_du_ptag_ordered_table(module_info, rtti_type_ctor,
    map(int, sectag_table)) = list(mlds__defn).

gen_du_ptag_ordered_table(ModuleInfo, RttiTypeCtor, PtagMap) = MLDS_Defns :-
    module_info_get_name(ModuleInfo, ModuleName),
    map__to_assoc_list(PtagMap, PtagList),
    SubDefns = list__map(gen_du_stag_ordered_table(ModuleName, RttiTypeCtor),
        PtagList),
    ( PtagList = [1 - _ | _] ->
            % Output a dummy ptag definition for the
            % reserved tag first.
        RttiElemName = du_ptag_layout(0),
        RttiElemId = ctor_rtti_id(RttiTypeCtor, RttiElemName),
        PtagInitPrefix = [
            init_struct(mlds__rtti_type(item_type(RttiElemId)),
            [gen_init_int(0),
            gen_init_builtin_const("MR_SECTAG_VARIABLE"),
            gen_init_null_pointer(
                mlds__rtti_type(item_type(
                    ctor_rtti_id(RttiTypeCtor, du_stag_ordered_table(0)))))]
        )],
        FirstPtag = 1
    ; PtagList = [0 - _ | _] ->
        PtagInitPrefix = [],
        FirstPtag = 0
    ; PtagList = [] ->
        PtagInitPrefix = [],
        FirstPtag = 0
    ;
        unexpected(this_file, "gen_du_ptag_ordered_table: bad ptag list")
    ),
    PtagInits = gen_du_ptag_ordered_table_body(ModuleName, RttiTypeCtor,
        PtagList, FirstPtag),
    RttiName = du_ptag_ordered_table,
    Init = init_array(list__append(PtagInitPrefix, PtagInits)),
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn),
    MLDS_Defns = list__append(SubDefns, [MLDS_Defn]).

:- func gen_du_ptag_ordered_table_body(module_name, rtti_type_ctor,
    assoc_list(int, sectag_table), int) = list(mlds__initializer).

gen_du_ptag_ordered_table_body(_, _, [], _) = [].
gen_du_ptag_ordered_table_body(ModuleName, RttiTypeCtor,
        [Ptag - SectagTable | PtagTail], CurPtag) = [Init | Inits] :-
    require(unify(Ptag, CurPtag),
        "gen_du_ptag_ordered_table_body: ptag mismatch"),
    SectagTable = sectag_table(SectagLocn, NumSharers, _SectagMap),
    RttiName = du_ptag_layout(Ptag),
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_int(NumSharers),
        gen_init_sectag_locn(SectagLocn),
        gen_init_rtti_name(ModuleName, RttiTypeCtor,
            du_stag_ordered_table(Ptag))
    ]),
    Inits = gen_du_ptag_ordered_table_body(ModuleName, RttiTypeCtor,
        PtagTail, CurPtag + 1).

:- func gen_du_stag_ordered_table(module_name, rtti_type_ctor,
    pair(int, sectag_table)) = mlds__defn.

gen_du_stag_ordered_table(ModuleName, RttiTypeCtor, Ptag - SectagTable)
        = MLDS_Defn :-
    SectagTable = sectag_table(_SectagLocn, _NumSharers, SectagMap),
    map__values(SectagMap, SectagFunctors),
    FunctorRttiNames = list__map(du_functor_rtti_name, SectagFunctors),
    Init = gen_init_rtti_names_array(ModuleName, RttiTypeCtor,
        FunctorRttiNames),
    RttiName = du_stag_ordered_table(Ptag),
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_du_name_ordered_table(module_info, rtti_type_ctor,
    map(string, map(int, du_functor))) = mlds__defn.

gen_du_name_ordered_table(ModuleInfo, RttiTypeCtor, NameArityMap)
        = MLDS_Defn :-
    map__values(NameArityMap, ArityMaps),
    list__map(map__values, ArityMaps, FunctorLists),
    list__condense(FunctorLists, Functors),
    module_info_get_name(ModuleInfo, ModuleName),
    FunctorRttiNames = list__map(du_functor_rtti_name, Functors),
    Init = gen_init_rtti_names_array(ModuleName, RttiTypeCtor,
        FunctorRttiNames),
    RttiName = du_name_ordered_table,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_maybe_res_value_ordered_table(module_info, rtti_type_ctor,
    list(reserved_functor), map(int, sectag_table)) = list(mlds__defn).

gen_maybe_res_value_ordered_table(ModuleInfo, RttiTypeCtor, ResFunctors,
        DuByPtag) = MLDS_Defns :-
    ResFunctorReps = list__map(res_addr_rep, ResFunctors),
    list__filter(res_addr_is_numeric, ResFunctorReps,
        NumericResFunctorReps, SymbolicResFunctorReps),
    list__length(NumericResFunctorReps, NumNumericResFunctorReps),
    list__length(SymbolicResFunctorReps, NumSymbolicResFunctorReps),
    module_info_get_name(ModuleInfo, ModuleName),
    ResDefns = [gen_res_addr_functor_table(ModuleName, RttiTypeCtor,
        ResFunctors)],
    ( NumSymbolicResFunctorReps = 0 ->
        ResAddrDefns = [],
        ResAddrInit = gen_init_null_pointer(mlds__generic_type)
    ;
        ResAddrDefns = [gen_res_addrs_list(ModuleInfo, RttiTypeCtor,
            SymbolicResFunctorReps)],
        ResAddrInit = gen_init_rtti_name(ModuleName, RttiTypeCtor, res_addrs)
    ),
    DuDefns = gen_du_ptag_ordered_table(ModuleInfo, RttiTypeCtor, DuByPtag),
    SubDefns = list__condense([ResDefns, ResAddrDefns, DuDefns]),
    RttiName = res_value_ordered_table,
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Init = init_struct(mlds__rtti_type(item_type(RttiId)), [
        gen_init_int(NumNumericResFunctorReps),
        gen_init_int(NumSymbolicResFunctorReps),
        ResAddrInit,
        gen_init_rtti_name(ModuleName, RttiTypeCtor, res_addr_functors),
        gen_init_rtti_name(ModuleName, RttiTypeCtor, du_ptag_ordered_table)
    ]),
    rtti_id_and_init_to_defn(RttiId, Init, MLDS_Defn),
    MLDS_Defns = list__append(SubDefns, [MLDS_Defn]).

:- func gen_res_addr_functor_table(module_name, rtti_type_ctor,
    list(reserved_functor)) = mlds__defn.

gen_res_addr_functor_table(ModuleName, RttiTypeCtor, ResFunctors) = MLDS_Defn :-
    FunctorRttiNames = list__map(res_functor_rtti_name, ResFunctors),
    Init = gen_init_rtti_names_array(ModuleName, RttiTypeCtor,
        FunctorRttiNames),
    RttiName = res_addr_functors,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_res_addrs_list(module_info, rtti_type_ctor, list(reserved_address))
    = mlds__defn.

gen_res_addrs_list(ModuleInfo, RttiTypeCtor, ResAddrs) = MLDS_Defn :-
    Init = gen_init_array(gen_init_reserved_address(ModuleInfo), ResAddrs),
    RttiName = res_addrs,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_maybe_res_name_ordered_table(module_info, rtti_type_ctor,
    map(string, map(int, maybe_reserved_functor))) = mlds__defn.

gen_maybe_res_name_ordered_table(ModuleInfo, RttiTypeCtor, NameArityMap)
        = MLDS_Defn :-
    map__values(NameArityMap, ArityMaps),
    list__map(map__values, ArityMaps, FunctorLists),
    list__condense(FunctorLists, Functors),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = gen_init_array(
        gen_maybe_res_name_ordered_table_element(ModuleName, RttiTypeCtor),
        Functors),
    RttiName = res_name_ordered_table,
    rtti_name_and_init_to_defn(RttiTypeCtor, RttiName, Init, MLDS_Defn).

:- func gen_maybe_res_name_ordered_table_element(module_name, rtti_type_ctor,
    maybe_reserved_functor) = mlds__initializer.

gen_maybe_res_name_ordered_table_element(ModuleName, RttiTypeCtor,
        MaybeResFunctor) = Init :-
    RttiName = maybe_res_addr_functor_desc,
    RttiId = ctor_rtti_id(RttiTypeCtor, RttiName),
    Type = mlds__rtti_type(item_type(RttiId)),
    (
        MaybeResFunctor = res_func(ResFunctor),
        Name = ResFunctor ^ res_name,
        Init = init_struct(Type, [
            gen_init_string(Name),
            gen_init_int(0),    % arity=0
            gen_init_bool(yes), % is_reserved = true
            gen_init_rtti_name(ModuleName, RttiTypeCtor,
                maybe_res_functor_rtti_name(MaybeResFunctor))
        ])
    ;
        MaybeResFunctor = du_func(DuFunctor),
        Name = DuFunctor ^ du_name,
        Init = init_struct(Type, [
            gen_init_string(Name),
            gen_init_int(DuFunctor ^ du_orig_arity),
            gen_init_bool(no), % is_reserved = false
            gen_init_rtti_name(ModuleName, RttiTypeCtor,
                maybe_res_functor_rtti_name(MaybeResFunctor))
        ])
    ).

%-----------------------------------------------------------------------------%

:- func gen_init_rtti_names_array(module_name, rtti_type_ctor,
    list(ctor_rtti_name)) = mlds__initializer.

gen_init_rtti_names_array(ModuleName, RttiTypeCtor, RttiNames) =
    gen_init_array(gen_init_rtti_name(ModuleName, RttiTypeCtor), RttiNames).

:- func gen_init_rtti_datas_array(module_name, list(rtti_data)) =
    mlds__initializer.

gen_init_rtti_datas_array(ModuleName, RttiDatas) =
    gen_init_array(gen_init_rtti_data(ModuleName), RttiDatas).

:- func gen_init_cast_rtti_datas_array(mlds__type, module_name,
    list(rtti_data)) = mlds__initializer.

gen_init_cast_rtti_datas_array(Type, ModuleName, RttiDatas) =
    gen_init_array(gen_init_cast_rtti_data(Type, ModuleName), RttiDatas).

    % Generate the MLDS initializer comprising the rtti_name
    % for a given rtti_data, converted to mlds__generic_type.
    % XXX We don't need to pass the module_name down to here.
    %
:- func gen_init_cast_rtti_data(mlds__type, module_name, rtti_data) =
    mlds__initializer.

gen_init_cast_rtti_data(DestType, ModuleName, RttiData) = Initializer :-
    (
        RttiData = pseudo_type_info(type_var(VarNum))
    ->
        % rtti_data_to_name/3 does not handle this case
        SrcType = mlds__native_int_type,
        Initializer = init_obj(unop(gen_cast(SrcType, DestType),
            const(int_const(VarNum))))
    ;
        RttiData = base_typeclass_info(TCName, InstanceModuleName,
            InstanceString, _)
    ->
        SrcType = rtti_type(item_type(tc_rtti_id(TCName,
            base_typeclass_info(InstanceModuleName, InstanceString)))),
        MLDS_ModuleName = mercury_module_name_to_mlds(InstanceModuleName),
        MLDS_DataName = rtti(tc_rtti_id(TCName,
            base_typeclass_info(InstanceModuleName, InstanceString))),
        DataAddr = data_addr(MLDS_ModuleName, MLDS_DataName),
        Rval = const(data_addr_const(DataAddr)),
        Initializer = init_obj(unop(gen_cast(SrcType, DestType), Rval))
    ;
        rtti_data_to_id(RttiData, RttiId),
        Initializer = gen_init_cast_rtti_id(DestType, ModuleName, RttiId)
    ).

    % Currently casts only store the destination type.
    %
:- func gen_cast(mlds__type, mlds__type) = mlds__unary_op.

gen_cast(_SrcType, DestType) = cast(DestType).

    % Generate the MLDS initializer comprising the rtti_name
    % for a given rtti_data.
    %
:- func gen_init_rtti_data(module_name, rtti_data) = mlds__initializer.

gen_init_rtti_data(ModuleName, RttiData) = Initializer :-
    rtti_data_to_id(RttiData, RttiId),
    Initializer = gen_init_rtti_id(ModuleName, RttiId).

    % Generate an MLDS initializer comprising just the
    % the rval for a given rtti_id.
    %
:- func gen_init_rtti_id(module_name, rtti_id) = mlds__initializer.

gen_init_rtti_id(ModuleName, ctor_rtti_id(RttiTypeCtor, RttiName)) =
    gen_init_rtti_name(ModuleName, RttiTypeCtor, RttiName).
gen_init_rtti_id(ModuleName, tc_rtti_id(TCName, TCRttiName)) =
    gen_init_tc_rtti_name(ModuleName, TCName, TCRttiName).
gen_init_rtti_id(ModuleName, aditi_rtti_id(ProcLabel)) =
    gen_init_aditi_rtti_name(ModuleName, ProcLabel).

    % Generate an MLDS initializer comprising just the
    % the rval for a given rtti_name.
    %
:- func gen_init_rtti_name(module_name, rtti_type_ctor, ctor_rtti_name) =
    mlds__initializer.

gen_init_rtti_name(ModuleName, RttiTypeCtor, RttiName) =
    init_obj(gen_rtti_name(ModuleName, RttiTypeCtor, RttiName)).

    % Generate an MLDS initializer comprising just the
    % the rval for a given tc_rtti_name.
    %
:- func gen_init_tc_rtti_name(module_name, tc_name, tc_rtti_name) =
    mlds__initializer.

gen_init_tc_rtti_name(ModuleName, TCName, TCRttiName) =
    init_obj(gen_tc_rtti_name(ModuleName, TCName, TCRttiName)).

    % Generate an MLDS initializer comprising just the
    % the rval for a given aditi_rtti_name.
    %
:- func gen_init_aditi_rtti_name(module_name, rtti_proc_label) =
    mlds__initializer.

gen_init_aditi_rtti_name(ModuleName, ProcLabel) =
    init_obj(gen_aditi_rtti_name(ModuleName, ProcLabel)).

    % Generate the MLDS initializer comprising the rtti_name
    % for a given rtti_name, converted to the given type.
    %
:- func gen_init_cast_rtti_id(mlds__type, module_name, rtti_id)
    = mlds__initializer.

gen_init_cast_rtti_id(DestType, ModuleName, RttiId) = Initializer :-
    SrcType = rtti_type(item_type(RttiId)),
    Initializer = init_obj(unop(gen_cast(SrcType, DestType),
        gen_rtti_id(ModuleName, RttiId))).

    % Generate the MLDS rval for an rtti_id.
    %
:- func gen_rtti_id(module_name, rtti_id) = mlds__rval.

gen_rtti_id(ThisModuleName, ctor_rtti_id(RttiTypeCtor, RttiName)) =
    gen_rtti_name(ThisModuleName, RttiTypeCtor, RttiName).
gen_rtti_id(ThisModuleName, tc_rtti_id(TCName, TCRttiName)) =
    gen_tc_rtti_name(ThisModuleName, TCName, TCRttiName).
gen_rtti_id(ThisModuleName, aditi_rtti_id(ProcLabel)) =
    gen_aditi_rtti_name(ThisModuleName, ProcLabel).

:- func gen_rtti_name(module_name, rtti_type_ctor, ctor_rtti_name)
    = mlds__rval.

gen_rtti_name(ThisModuleName, RttiTypeCtor0, RttiName) = Rval :-
    % Typeinfos and pseudo typeinfos are defined locally to each module.
    % Other kinds of RTTI data are defined in the module that defines
    % the type which they are for.
    (
        (
            RttiName = type_info(TypeInfo),
            ( TypeInfo = plain_type_info(_, _)
            ; TypeInfo = var_arity_type_info(_, _)
            )
        ;
            RttiName = pseudo_type_info(PseudoTypeInfo),
            ( PseudoTypeInfo = plain_pseudo_type_info(_, _)
            ; PseudoTypeInfo = var_arity_pseudo_type_info(_, _)
            )
        )
    ->
        ModuleName = ThisModuleName,
        RttiTypeCtor = RttiTypeCtor0
    ;
        RttiTypeCtor0 = rtti_type_ctor(RttiModuleName,
            RttiTypeName, RttiTypeArity),

        % Although the builtin types `int', `float', etc. are treated
        % as part of the `builtin' module, for historical reasons they
        % don't have any qualifiers at this point, so we need to add
        % the `builtin' qualifier now.
        ( RttiModuleName = unqualified("") ->
            mercury_public_builtin_module(ModuleName),
            RttiTypeCtor = rtti_type_ctor(RttiModuleName,
                RttiTypeName, RttiTypeArity)
        ;
            ModuleName = RttiModuleName,
            RttiTypeCtor = RttiTypeCtor0
        )
    ),
    MLDS_ModuleName = mercury_module_name_to_mlds(ModuleName),
    MLDS_DataName = rtti(ctor_rtti_id(RttiTypeCtor, RttiName)),
    DataAddr = data_addr(MLDS_ModuleName, MLDS_DataName),
    Rval = const(data_addr_const(DataAddr)).

:- func gen_tc_rtti_name(module_name, tc_name, tc_rtti_name) = mlds__rval.

gen_tc_rtti_name(_ThisModuleName, TCName, TCRttiName) = Rval :-
    (
        TCRttiName = base_typeclass_info(InstanceModuleName, _),
        MLDS_ModuleName = mercury_module_name_to_mlds(InstanceModuleName)
    ;
        TCRttiName = type_class_id,
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_decl,
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_decl_super(_, _),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_decl_supers,
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_id_var_names,
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_id_method_ids,
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_instance(_Types),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_instance_tc_type_vector(_Types),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_instance_constraint(_Types, _, _),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_instance_constraints(_Types),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ;
        TCRttiName = type_class_instance_methods(_Types),
        MLDS_ModuleName = mlds_module_name_from_tc_name(TCName)
    ),
    MLDS_DataName = rtti(tc_rtti_id(TCName, TCRttiName)),
    DataAddr = data_addr(MLDS_ModuleName, MLDS_DataName),
    Rval = const(data_addr_const(DataAddr)).

:- func gen_aditi_rtti_name(module_name, rtti_proc_label) = mlds__rval.

gen_aditi_rtti_name(ThisModuleName, ProcLabel) = Rval :-
    MLDS_ModuleName = mercury_module_name_to_mlds(ThisModuleName),
    MLDS_DataName = rtti(aditi_rtti_id(ProcLabel)),
    DataAddr = data_addr(MLDS_ModuleName, MLDS_DataName),
    Rval = const(data_addr_const(DataAddr)).

:- func mlds_module_name_from_tc_name(tc_name) = mlds_module_name.

mlds_module_name_from_tc_name(TCName) = MLDS_ModuleName :-
    TCName = tc_name(ModuleName, _ClassName, _Arity),
    MLDS_ModuleName = mercury_module_name_to_mlds(ModuleName).

%-----------------------------------------------------------------------------%

:- pred gen_pseudo_type_info(module_info::in, rtti_data::in,
    mlds__initializer::out, list(mlds__defn)::out) is det.

gen_pseudo_type_info(ModuleInfo, PTIRttiData, Init, Defns) :-
    RealRttiDatas = list__filter(real_rtti_data, [PTIRttiData]),
    DefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    Defns = list__condense(DefnLists),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = gen_init_cast_rtti_data(mlds__pseudo_type_info_type,
        ModuleName, PTIRttiData).

:- pred gen_pseudo_type_info_array(module_info::in, list(rtti_data)::in,
    mlds__initializer::out, list(mlds__defn)::out) is det.

gen_pseudo_type_info_array(ModuleInfo, PTIRttiDatas, Init, Defns) :-
    RealRttiDatas = list__filter(real_rtti_data, PTIRttiDatas),
    DefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    Defns = list__condense(DefnLists),
    module_info_get_name(ModuleInfo, ModuleName),
    Init = gen_init_cast_rtti_datas_array(mlds__pseudo_type_info_type,
        ModuleName, PTIRttiDatas).

:- pred gen_pseudo_type_info_list(module_info::in, list(rtti_data)::in,
    list(mlds__initializer)::out, list(mlds__defn)::out) is det.

gen_pseudo_type_info_list(ModuleInfo, PTIRttiDatas, Inits, Defns) :-
    RealRttiDatas = list__filter(real_rtti_data, PTIRttiDatas),
    DefnLists = list__map(rtti_data_to_mlds(ModuleInfo), RealRttiDatas),
    Defns = list__condense(DefnLists),
    module_info_get_name(ModuleInfo, ModuleName),
    Inits = list__map(
        gen_init_cast_rtti_data(mlds__pseudo_type_info_type, ModuleName),
        PTIRttiDatas).

%-----------------------------------------------------------------------------%

:- pred gen_init_method(module_info::in, int::in, rtti_proc_label::in,
    mlds__initializer::out, list(mlds__defn)::in, list(mlds__defn)::out)
    is det.

gen_init_method(ModuleInfo, NumExtra, RttiProcLabel, Init, !ExtraDefns) :-
    % We can't store the address of the typeclass method directly in the
    % base_typeclass_info; instead, we need to generate a wrapper function
    % that extracts the NumExtra parameters it needs from the typeclass_info,
    % and store the address of that wrapper function in the
    % base_typeclass_info.
    %
    % Note that this means there are two levels of wrappers: the wrapper that
    % we generate here calls the procedure introduced by check_typeclass.m,
    % and that in turn calls the user's procedure. Hopefully the Mercury
    % HLDS->HLDS inlining and/or the target code compiler will be able
    % to optimize this...
    %
    gen_wrapper_func_and_initializer(ModuleInfo, NumExtra, RttiProcLabel,
        typeclass_info_closure, Init, !ExtraDefns).

:- pred gen_init_special_pred(module_info::in, univ::in, mlds__initializer::out,
    list(mlds__defn)::in, list(mlds__defn)::out) is det.

gen_init_special_pred(ModuleInfo, RttiProcIdUniv, Init, !ExtraDefns) :-
    % We can't store the address of the special pred procedure directly in the
    % type_ctor_info because when the special pred is called by looking up
    % its address in the type_ctor_info its always called with its arguments
    % boxed, but the generated special pred may operate on unboxed values,
    % hence we need to generate a wrapper function which unboxes the arguments
    % if necessary.
    ( univ_to_type(RttiProcIdUniv, RttiProcId) ->
        ( RttiProcId ^ proc_arity = 0 ->
            % If there are no arguments, then there's no unboxing to do,
            % so we don't need a wrapper. (This case can occur with
            % --no-special-preds, where the procedure will be
            % private_builtin.unused/0.)
            Init = gen_init_proc_id(ModuleInfo, RttiProcId)
        ;
            NumExtra = 0,
            gen_wrapper_func_and_initializer(ModuleInfo, NumExtra,
                RttiProcId, special_pred, Init, !ExtraDefns)
        )
    ;
        unexpected(this_file,
            "gen_init_special_pred: cannot extract univ value")
    ).

:- pred gen_wrapper_func_and_initializer(module_info::in, int::in,
    rtti_proc_label::in, closure_kind::in, mlds__initializer::out,
    list(mlds__defn)::in, list(mlds__defn)::out) is det.

gen_wrapper_func_and_initializer(ModuleInfo, NumExtra, RttiProcId,
        ClosureKind, Init, ExtraDefns0, ExtraDefns) :-
    % We start off by creating a fresh MLGenInfo here, using the pred_id and
    % proc_id of the wrapped procedure. This requires considerable care.
    % We need to call ml_gen_info_bump_counters to ensure that the function
    % label allocated for the wrapper func does not overlap with any function
    % labels used when generating code for the wrapped procedure.
    %
    PredId = RttiProcId ^ pred_id,
    ProcId = RttiProcId ^ proc_id,
    MLGenInfo0 = ml_gen_info_init(ModuleInfo, PredId, ProcId),
    ml_gen_info_bump_counters(MLGenInfo0, MLGenInfo1),

    % Now we can safely go ahead and generate the wrapper function.
    term__context_init(Context),
    ml_gen_closure_wrapper(PredId, ProcId, ClosureKind, NumExtra, Context,
        WrapperFuncRval, WrapperFuncType, MLGenInfo1, MLGenInfo),
    ml_gen_info_get_extra_defns(MLGenInfo, ExtraDefns1),
    ExtraDefns = list__append(ExtraDefns1, ExtraDefns0),

    % The initializer for the wrapper is just the wrapper function's address,
    % converted to mlds__generic_type (by boxing).
    Init = init_obj(unop(box(WrapperFuncType), WrapperFuncRval)).

:- func gen_init_proc_id(module_info, rtti_proc_label) = mlds__initializer.

gen_init_proc_id(ModuleInfo, RttiProcId) = Init :-
    % Construct an rval for the address of this procedure
    % (this is similar to ml_gen_proc_addr_rval).
    ml_gen_pred_label_from_rtti(ModuleInfo, RttiProcId, PredLabel, PredModule),
    ProcId = RttiProcId ^ proc_id,
    QualifiedProcLabel = qual(PredModule, module_qual, PredLabel - ProcId),
    Params = ml_gen_proc_params_from_rtti(ModuleInfo, RttiProcId),
    Signature = mlds__get_func_signature(Params),
    ProcAddrRval = const(code_addr_const(proc(QualifiedProcLabel, Signature))),

    % Convert the procedure address to a generic type. We need to use a
    % generic type because since the actual type for the procedure will
    % depend on how many type_info parameters it takes, which will depend
    % on the type's arity.
    ProcAddrArg = unop(box(mlds__func_type(Params)), ProcAddrRval),
    Init = init_obj(ProcAddrArg).

:- func gen_init_proc_id_from_univ(module_info, univ) =
    mlds__initializer.

gen_init_proc_id_from_univ(ModuleInfo, ProcLabelUniv) = Init :-
    ( univ_to_type(ProcLabelUniv, ProcLabel) ->
        Init = gen_init_proc_id(ModuleInfo, ProcLabel)
    ;
        error("gen_init_proc_id_from_univ: cannot extract univ value")
    ).

    % Succeed iff the specified rtti_data is one that requires an
    % explicit mlds__defn to define it.
    %
:- pred real_rtti_data(rtti_data::in) is semidet.

real_rtti_data(RttiData) :-
    \+ (
        (
            RttiData = type_info(TypeInfo),
            TypeInfo = plain_arity_zero_type_info(_)
        ;
            RttiData = pseudo_type_info(PseudoTypeInfo),
            ( PseudoTypeInfo = plain_arity_zero_pseudo_type_info(_)
            ; PseudoTypeInfo = type_var(_)
            )
        )
    ).

%-----------------------------------------------------------------------------%
%
% Conversion functions for builtin enumeration types.
%
% This handles sectag_locn and type_ctor_rep. The rvals generated are just
% named constants in the private_builtin module, which the Mercury runtime
% is expected to define.

:- func gen_init_pred_or_func(pred_or_func) = mlds__initializer.

gen_init_pred_or_func(PredOrFunc) = gen_init_builtin_const(Name) :-
    rtti__pred_or_func_to_string(PredOrFunc, Name).

:- func gen_init_sectag_locn(sectag_locn) = mlds__initializer.

gen_init_sectag_locn(Locn) = gen_init_builtin_const(Name) :-
    rtti__sectag_locn_to_string(Locn, Name).

:- func gen_init_type_ctor_rep(type_ctor_data) = mlds__initializer.

gen_init_type_ctor_rep(TypeCtorData) = gen_init_builtin_const(Name) :-
    rtti__type_ctor_rep_to_string(TypeCtorData, Name).

:- func gen_init_builtin_const(string) = mlds__initializer.

gen_init_builtin_const(Name) = init_obj(Rval) :-
        mercury_private_builtin_module(PrivateBuiltin),
    MLDS_Module = mercury_module_name_to_mlds(PrivateBuiltin),
    % XXX These are actually enumeration constants.
    % Perhaps we should be using an enumeration type here,
    % rather than `mlds__native_int_type'.
    Type = mlds__native_int_type,
    Rval = lval(var(qual(MLDS_Module, module_qual, var_name(Name, no)), Type)).

%-----------------------------------------------------------------------------%
%
% Conversion functions for the basic types.
%
% This handles arrays, maybe, null pointers, strings, and ints.

:- func gen_init_array(func(T) = mlds__initializer, list(T)) =
    mlds__initializer.

gen_init_array(Conv, List) = init_array(list__map(Conv, List)).

:- func gen_init_maybe(mlds__type, func(T) = mlds__initializer, maybe(T)) =
    mlds__initializer.

gen_init_maybe(_Type, Conv, yes(X)) = Conv(X).
gen_init_maybe(Type, _Conv, no) = gen_init_null_pointer(Type).

:- func gen_init_null_pointer(mlds__type) = mlds__initializer.

gen_init_null_pointer(Type) = init_obj(const(null(Type))).

:- func gen_init_string(string) = mlds__initializer.

gen_init_string(String) = init_obj(const(string_const(String))).

:- func gen_init_int(int) = mlds__initializer.

gen_init_int(Int) = init_obj(const(int_const(Int))).

:- func gen_init_bool(bool) = mlds__initializer.

gen_init_bool(no) = init_obj(const(false)).
gen_init_bool(yes) = init_obj(const(true)).

:- func gen_init_boxed_int(int) = mlds__initializer.

gen_init_boxed_int(Int) =
    init_obj(unop(box(mlds__native_int_type), const(int_const(Int)))).

:- func gen_init_reserved_address(module_info, reserved_address) =
    mlds__initializer.

gen_init_reserved_address(ModuleInfo, ReservedAddress) =
    % XXX using `mlds__generic_type' here is probably wrong
    init_obj(ml_gen_reserved_address(ModuleInfo, ReservedAddress,
        mlds__generic_type)).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "rtti_to_mlds.m".

%-----------------------------------------------------------------------------%
