%-----------------------------------------------------------------------------%
% Copyright (C) 1998-1999 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% File: rl_sort.m
% Main author: stayl
%
% Work out what sorting and indexing is available, and introduce
% sort-merge or indexed operations where possible. 
%
% Remove unnecessary sort and add_index operations.
%
% 
% Eventually this module should:
%
% Generate sort and add_index instructions where required. This should be
% performed after other optimization passes which introduce sort-merge
% operations. (There are none yet). At the moment sorts are inserted where
% they might be required by rl_gen.m, but for example a union may be optimized
% into a union_diff and no longer require sorted input.
%
% For some operations such as sort-merge union, all that is required
% is that all inputs are sorted on all of their attributes.
% For these, we will eventually use a `sort variable', which stands for
% any sort specifier which sorts on all attributes - it is up to this
% module to work out which attribute ordering to use.
%
% Not yet, if ever - All inputs to a call are assumed to be sorted in
% ascending order on ascending attributes, and outputs are returned sorted
% the same way - I'm not sure if this is a good idea.
%
%-----------------------------------------------------------------------------%
:- module rl_sort.

:- interface.

:- import_module rl_block.
:- import_module io.

:- pred rl_sort__proc(rl_opt_info, rl_opt_info, io__state, io__state).
:- mode rl_sort__proc(in, out, di, uo) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds_module, prog_data, rl, rl_analyse, rl_key.
:- import_module assoc_list, bool, int, list, map, relation, require, set.
:- import_module std_util.

rl_sort__proc(Opt0, Opt, IO0, IO) :-
	rl_sort__proc_2(IO0, IO, Opt0, Opt).

:- pred rl_sort__proc_2(io__state, io__state, rl_opt_info, rl_opt_info).
:- mode rl_sort__proc_2(di, uo, in, out) is det.

rl_sort__proc_2(IO0, IO) -->
	rl_opt_info_get_first_block_id(FirstBlock),
	rl_opt_info_get_last_block_id(LastBlock),

	% Memoed relations are either guaranteed to be empty at the start
	% of the first block or sorted as they were at the end of the last
	% block, so we add an extra arc in the flow graph to take this into
	% account. The confluence operator must ensure that required
	% sortedness for memoed relations only is propagated along this arc.
	rl_opt_info_get_memoed_relations(MemoedRels),
	( { set__empty(MemoedRels) } ->
		[]
	;
		rl_opt_info_get_flow_graph(FlowGraph0),	
		{ relation__lookup_element(FlowGraph0, FirstBlock, FirstKey) },
		{ relation__lookup_element(FlowGraph0, LastBlock, LastKey) },
		{ relation__add(FlowGraph0, LastKey, FirstKey, FlowGraph1) },
		rl_opt_info_set_flow_graph(FlowGraph1)
	),

	%
	% The forward pass - work out which relations are
	% sorted at the start of each block.
	%
	{ map__init(AvailSortMap0) },
	rl_opt_info_get_rev_block_order(RevOrder),
	{ list__reverse(RevOrder, Order) },
	list__foldl2(rl_sort__init_block,
		RevOrder, AvailSortMap0, AvailSortMap1),

	{ AvailSortConfluence = rl_sort__confluence },
	{ AvailSortBlockUpdate = rl_sort__avail_block_update },
	{ AvailSortEqual = rl_sort__unify },
	{ AvailSortWrite = rl_sort__write_sort_data },

	{ AvailSortAnalysis = 
		rl_analysis(
			forward,
			AvailSortConfluence,
			AvailSortBlockUpdate,
			AvailSortEqual,
			AvailSortWrite
		) },
			
	{ map__init(AvailVarRequests0) },
	rl_analyse(Order, AvailSortAnalysis, AvailSortMap1, AvailSortMap,
		AvailVarRequests0, _AvailVarRequests, IO0, IO1),

	% 	
	% Go through the instructions using joins and indexes where possible.
	%
	list__foldl(rl_sort__exploit_sorting_and_indexing(AvailSortMap),
		Order),

	%
	% Work out which relations are required to be sorted at
	% the end of each block.
	%
	{ map__init(NeededSortMap0) },
	list__foldl2(rl_sort__init_block,
		RevOrder, NeededSortMap0, NeededSortMap1),

	{ NeededSortConfluence = rl_sort__confluence },
	{ NeededSortBlockUpdate = rl_sort__needed_block_update },
	{ NeededSortEqual = rl_sort__unify },
	{ NeededSortWrite = rl_sort__write_sort_data },

	{ NeededSortAnalysis = 
		rl_analysis(
			backward,
			NeededSortConfluence,
			NeededSortBlockUpdate,
			NeededSortEqual,
			NeededSortWrite
		) },
			
	{ map__init(NeededVarRequests0) },
	rl_analyse(RevOrder, NeededSortAnalysis, NeededSortMap1,
		NeededSortMap, NeededVarRequests0, _NeededVarRequests,
		IO1, IO),

	%
	% Go through the instructions removing unnecessary
	% sorts and add_indexes.
	%
	list__foldl(rl_sort__remove_useless_ops(NeededSortMap), Order),

	%
	% Remove the arc we added for memoed relations.
	%
	( { set__empty(MemoedRels) } ->
		[]
	;
		rl_opt_info_get_flow_graph(FlowGraph2),	
		{ relation__lookup_element(FlowGraph2, FirstBlock, FirstKey1) },
		{ relation__lookup_element(FlowGraph2, LastBlock, LastKey1) },
		{ relation__remove(FlowGraph2, LastKey1,
			FirstKey1, FlowGraph) },
		rl_opt_info_set_flow_graph(FlowGraph)
	).

	% For each relation_id, record every required sortedness.
	% We'll eventually have to pick one for each relation_id at each point.
:- type sort_data == block_data(sortedness, unit).

:- type sortedness
	---> sortedness(
		relation_sort_map,
		var_sort_map
	).

:- type sort_index
	--->	sort(sort_spec)
	;	index(index_spec)	
	.

:- type relation_sort_map == map(relation_id, map(sort_index, sort_req)).
:- type var_sort_map == map(int, set(relation_id)).

	% Possible sortednesses for each sortedness variable.
	% This is passed globally.
:- type var_requests == map(int, set(sort_index)).

:- type sort_info
	--->	sort_info(
			sortedness,
			var_requests,
			rl_opt_info
		).

:- type sort_req 
	---> sort_req(
		is_definite,
		set(block_id)	% requesting/producing blocks
	).

:- type is_definite
	--->	definite	% This sortedness is definitely required.
	;	maybe
				% This sortedness is possibly required.
				% Record which block_ids requested this
				% sortedness.
				% Sortednesses required within the loop
				% are preferred.
	.

:- type sort_data_map == block_data_map(sortedness, unit).

%-----------------------------------------------------------------------------%

	% Filter out unneeded specs.
:- type spec_filter ==  pred(pair(sort_index, sort_req)).
:- inst spec_filter == (pred(in) is semidet).

:- func true_filter = (spec_filter::out(spec_filter)) is det.
true_filter = (pred(_::in) is semidet :- true).

:- func sort_filter = (spec_filter::out(spec_filter)) is det.
sort_filter = (pred((sort(_) - _)::in) is semidet).

:- func index_filter = (spec_filter::out(spec_filter)) is det.
index_filter = (pred((index(_) - _)::in) is semidet).

%-----------------------------------------------------------------------------%

:- pred rl_sort__init_block(block_id::in, sort_data_map::in,
		sort_data_map::out, rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__init_block(BlockId, SortData0, SortData) -->
	{ map__init(SortMap0) },
	{ map__init(SortBindings0) },
	{ Value = sortedness(SortMap0, SortBindings0) },
	{ BlockData = block_data(Value, Value, unit) },
	{ map__det_insert(SortData0, BlockId, BlockData, SortData) }.

%-----------------------------------------------------------------------------%

:- pred rl_sort__unify(sortedness::in, sortedness::in,
		var_requests::in) is semidet.

rl_sort__unify(sortedness(RelMap1, VarMap1),
		sortedness(RelMap2, VarMap2), _) :-
	rl_sort__map_equal(rl_sort__map_equal(unify), RelMap1, RelMap2),
	rl_sort__map_equal(unify, VarMap1, VarMap2).

:- pred rl_sort__map_equal(pred(V, V), map(K, V), map(K, V)).
:- mode rl_sort__map_equal(pred(in, in) is semidet, in, in) is semidet.

rl_sort__map_equal(UnifyValue, Map1, Map2) :-
	map__foldl(
		lambda([Key1::in, Value1::in, _Unit0::in, Unit::out] is semidet,
		(
			Unit = unit,
			map__search(Map2, Key1, Value2),
			call(UnifyValue, Value1, Value2)
		)), Map1, unit, _).

%-----------------------------------------------------------------------------%

	% Merge the information from multiple blocks.
:- pred rl_sort__confluence(pair(block_id, sortedness)::in,
		pair(block_id, maybe(sortedness))::in, sortedness::out,
		var_requests::in, var_requests::out,
		rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__confluence(CalledBlockId - CalledSortData0,
		ThisBlockId - MaybeSortData0, SortData,
		VarRequests, VarRequests) -->
	rl_opt_info_get_last_block_id(LastBlockId),
	rl_opt_info_get_first_block_id(FirstBlockId),
	(
		(
			{ ThisBlockId = LastBlockId },
			{ CalledBlockId = FirstBlockId }
		;
			{ ThisBlockId = FirstBlockId },
			{ CalledBlockId = LastBlockId }
		)
	->
		% Restrict the passed in data from the first block
		% to the memoed relations.
		rl_opt_info_get_memoed_relations(MemoedRels),
		{ rl_sort__restrict(CalledSortData0,
			MemoedRels, CalledSortData) }
	;
		{ CalledSortData = CalledSortData0 }
	),
	
	{ MaybeSortData0 = yes(SortData0) ->
		SortData0 = sortedness(SortedRels0, SortVars0),
		CalledSortData = sortedness(CalledSortedRels,
					CalledSortVars),
		rl_sort__merge_sort_maps(SortedRels0,
			CalledSortedRels, SortedRels),
		rl_sort__merge_maps(SortVars0,
			CalledSortVars, SortVars),
		SortData = sortedness(SortedRels, SortVars)
	;
		SortData = CalledSortData
	}.
	
:- pred rl_sort__merge_maps(map(T, set(U))::in, map(T, set(U))::in, 
		map(T, set(U))::out) is det.

rl_sort__merge_maps(Map1, Map2, Map) :-
	AddToMap =
	    lambda([Key::in, Value::in, MergedMap0::in, MergedMap::out] is det, 
	    (
	    	( map__search(MergedMap0, Key, Value0) ->
			set__union(Value0, Value, MergedValue),
			map__det_update(MergedMap0, Key,
				MergedValue, MergedMap)
		;
			map__det_insert(MergedMap0, Key, Value, MergedMap)
		)
	    )),
	map__foldl(AddToMap, Map2, Map1, Map).

:- pred rl_sort__merge_sort_maps(relation_sort_map::in, relation_sort_map::in,
		relation_sort_map::out) is det.

rl_sort__merge_sort_maps(SortSpecs, Specs0, Specs) :-

	MergeMaps =
	    lambda([Key::in, Value1::in, MergedMap0::in, MergedMap::out] is det,
	    (
	    	( map__search(MergedMap0, Key, Value0) ->
			rl_sort__merge_sort_maps_2(Value1, Value0, Value),
			map__det_update(MergedMap0, Key, Value, MergedMap)
		;
			map__det_insert(MergedMap0, Key, Value1, MergedMap)
		)
	    )),
	map__foldl(MergeMaps, SortSpecs, Specs0, Specs).

:- pred rl_sort__merge_sort_maps_2(map(sort_index, sort_req)::in, 
	map(sort_index, sort_req)::in, map(sort_index, sort_req)::out) is det. 

rl_sort__merge_sort_maps_2(Map0, Map1, Map) :-
	MergeMaps =
	    lambda([Spec::in, Req1::in, MergedMap0::in, MergedMap::out] is det,
	    (
	    	( map__search(MergedMap0, Spec, Req0) ->
			rl_sort__merge_sort_reqs(Req0, Req1, Req),
			map__det_update(MergedMap0, Spec, Req, MergedMap)
		;
			map__det_insert(MergedMap0, Spec, Req1, MergedMap)
		)
	    )),
	map__foldl(MergeMaps, Map0, Map1, Map).

:- pred rl_sort__merge_sort_reqs(sort_req::in,
		sort_req::in, sort_req::out) is det.

rl_sort__merge_sort_reqs(Req0, Req1, Req) :-
	Req0 = sort_req(Definite0, BlockIds0),
	Req1 = sort_req(Definite1, BlockIds1),
	set__union(BlockIds0, BlockIds1, BlockIds),
	(
		( Definite0 = maybe
		; Definite1 = maybe
		)
	->
		Definite = maybe
	;
		Definite= definite
	),
	Req = sort_req(Definite, BlockIds).

:- pred rl_sort__restrict(sortedness::in, set(relation_id)::in,
		sortedness::out) is det.
	
rl_sort__restrict(SortData0, Rels, SortData) :-
	SortData0 = sortedness(SortedRels0, SortVars0),
	map__select(SortedRels0, Rels, SortedRels),
	IntersectRels = lambda([_::in, VarRels0::in, VarRels::out] is det, (
			set__intersect(VarRels0, Rels, VarRels)
		)),
	map__map_values(IntersectRels, SortVars0, SortVars),
	SortData = sortedness(SortedRels, SortVars).

%-----------------------------------------------------------------------------%

:- pred rl_sort__add_call_sortedness(block_id::in, relation_id::in,
		sort_info::in, sort_info::out) is det.

rl_sort__add_call_sortedness(_BlockId, _Output) --> [].
/*
	% XXX I'm not sure whether this is a good idea, so it's commented
	% out for now.
	rl_opt_info_get_relation_info(Output, OutputInfo),
	{ OutputInfo = relation_info(_, Schema, _, _) },
	{ rl__ascending_sort_spec(Schema, Spec) },
	{ rl_sort__add_relation_sortedness(BlockId, Spec, Output,
		Sortedness0, Sortedness) }.
*/

:- pred rl_sort__add_relation_sortedness(block_id::in, sort_index::in,
		relation_id::in, sort_info::in, sort_info::out) is det.

rl_sort__add_relation_sortedness(BlockId, Spec, RelationId) -->
	{ set__singleton_set(BlockIds, BlockId) },
	{ SortReq = sort_req(definite, BlockIds) },
	{ map__from_assoc_list([Spec - SortReq], Map) },
	rl_sort__add_relation_sortedness_map(Map, RelationId).

:- pred rl_sort__add_relation_sortedness_map(map(sort_index, sort_req)::in,
	relation_id::in, sort_info::in, sort_info::out) is det.

rl_sort__add_relation_sortedness_map(NewSortSpecs, RelationId,
		SortInfo0, SortInfo) :-
	SortInfo0 = sort_info(Sortedness0, VarReqs0, RLInfo),
	Sortedness0 = sortedness(RelMap0, VarMap0),
	( map__search(RelMap0, RelationId, SortSpecs0) ->
		map__keys(SortSpecs0, Specs0),
		set__sorted_list_to_set(Specs0, SpecSet0),
		rl_sort__get_vars(SpecSet0, Vars0),
		rl_sort__merge_sort_maps_2(NewSortSpecs,
			SortSpecs0, SortSpecs),
		map__det_update(RelMap0, RelationId, SortSpecs, RelMap)
	;
		set__init(Vars0),
		map__det_insert(RelMap0, RelationId,
			NewSortSpecs, RelMap),
		SortSpecs = NewSortSpecs
	),

	map__keys(NewSortSpecs, NewSpecs0),
	set__sorted_list_to_set(NewSpecs0, NewSpecs),
	map__keys(SortSpecs, Specs1),
	set__sorted_list_to_set(Specs1, Specs),
	rl_sort__get_vars(Specs, Vars),

	set__difference(Vars, Vars0, NewVars),
	set__difference(Vars, NewVars, OldVars),
	set__to_sorted_list(NewVars, NewVarsList),
	set__to_sorted_list(OldVars, OldVarsList),

	rl_sort__update_var_requests(OldVarsList, Specs, VarReqs0, VarReqs1),
	rl_sort__update_var_requests(NewVarsList, NewSpecs, VarReqs1, VarReqs),
	
	list__foldl(rl_sort__add_var_relation(RelationId), NewVarsList,
		VarMap0, VarMap),

	Sortedness = sortedness(RelMap, VarMap),
	SortInfo = sort_info(Sortedness, VarReqs, RLInfo).

:- pred rl_sort__get_vars(set(sort_index)::in, set(int)::out) is det.

rl_sort__get_vars(Specs, Vars) :-
	set__to_sorted_list(Specs, SpecList),
	rl_sort__get_vars_2(SpecList, Vars0),
	set__list_to_set(Vars0, Vars).	

:- pred rl_sort__get_vars_2(list(sort_index)::in, list(int)::out) is det.

rl_sort__get_vars_2([], []).
rl_sort__get_vars_2([sort(sort_var(Var)) | Specs], [Var | Vars]) :-
	rl_sort__get_vars_2(Specs, Vars).
rl_sort__get_vars_2([sort(attributes(_)) | _], []).
rl_sort__get_vars_2([index(_) | _], []).

:- pred rl_sort__update_var_requests(list(int)::in, set(sort_index)::in,
		var_requests::in, var_requests::out) is det.

rl_sort__update_var_requests([], _, VarReqs, VarReqs).
rl_sort__update_var_requests([Var | Vars], Specs1, VarReqs0, VarReqs) :-
	( map__search(VarReqs0, Var, Specs0) ->
		set__union(Specs0, Specs1, Specs),
		map__det_update(VarReqs0, Var, Specs, VarReqs1)
	;
		map__det_insert(VarReqs0, Var, Specs1, VarReqs1)
	),
	rl_sort__update_var_requests(Vars, Specs1, VarReqs1, VarReqs).

:- pred rl_sort__add_var_relation(relation_id::in, int::in,
		var_sort_map::in, var_sort_map::out) is det.

rl_sort__add_var_relation(RelationId, Var, VarMap0, VarMap) :-
	( map__search(VarMap0, Var, VarRels0) ->
		set__insert(VarRels0, RelationId, VarRels),
		map__det_update(VarMap0, Var, VarRels, VarMap)
	;
		set__singleton_set(VarRels, RelationId),
		map__det_insert(VarMap0, Var, VarRels, VarMap)
	).

:- pred rl_sort__remove_var_relation(relation_id::in, sort_index::in,
		sort_req::in, var_sort_map::in, var_sort_map::out) is det.

rl_sort__remove_var_relation(RelationId, SortSpec, _, VarMap0, VarMap) :-
	(
		SortSpec = sort(sort_var(Var)),
		map__search(VarMap0, Var, VarRels0)
	->
		set__delete(VarRels0, RelationId, VarRels),
		map__det_update(VarMap0, Var, VarRels, VarMap)
	;
		VarMap = VarMap0
	).

:- pred rl_sort__remove_relation_id(relation_id::in,
		sort_info::in, sort_info::out) is det.

rl_sort__remove_relation_id(RelationId, sort_info(Sortedness0, VarReq, C),
		sort_info(Sortedness, VarReq, C)) :-
	Sortedness0 = sortedness(RelMap0, VarMap0),
	( map__search(RelMap0, RelationId, SortSpecs) ->
		map__delete(RelMap0, RelationId, RelMap),
		map__foldl(rl_sort__remove_var_relation(RelationId),
			SortSpecs, VarMap0, VarMap),
		Sortedness = sortedness(RelMap, VarMap)
	;
		Sortedness = Sortedness0
	).

	% Add the required sortedness of the first relation
	% to that of the second.
:- pred rl_sort__assign_sortedness_and_indexing(block_id::in,
		relation_id::in, relation_id::in,
		sort_info::in, sort_info::out) is det.

rl_sort__assign_sortedness_and_indexing(BlockId,
		Relation1, Relation2) -->
	rl_sort__assign_sortedness_and_indexing(true_filter, BlockId,
		Relation1, Relation2).

:- pred rl_sort__assign_sortedness_and_indexing(spec_filter::in(spec_filter),
		block_id::in, relation_id::in, relation_id::in,
		sort_info::in, sort_info::out) is det.

rl_sort__assign_sortedness_and_indexing(SpecFilter, BlockId,
		Relation1, Relation2) -->
	=(sort_info(sortedness(RelMap0, _), _, RLInfo)),
	{ rl_opt_info_get_relation_info(Relation2, RelInfo, RLInfo, _) },
	( { RelInfo = relation_info(permanent(_), _, Indexes, _) } ->
		{ map__init(Specs0) },
		{ set__singleton_set(BlockIds, BlockId) },
		{ list__foldl(
			lambda([Index::in, SpecMap0::in, SpecMap::out] is det, 
			(
				map__set(SpecMap0, index(Index),
					sort_req(definite, BlockIds), SpecMap)
			)), Indexes, Specs0, Specs1) },
		{ map__to_assoc_list(Specs1, SpecAL1) },
		{ list__filter(SpecFilter, SpecAL1, SpecAL) },
		{ map__from_assoc_list(SpecAL, Specs) },
		rl_sort__add_relation_sortedness_map(Specs, Relation1)
	; { map__search(RelMap0, Relation2, Specs0) } ->
		{ map__to_assoc_list(Specs0, SpecAL0) },
		{ list__filter(SpecFilter, SpecAL0, SpecAL) },
		{ map__from_assoc_list(SpecAL, Specs) },
		rl_sort__add_relation_sortedness_map(Specs, Relation1)
	;
		[]
	).

:- pred rl_sort__handle_output_indexing(block_id::in, output_rel::in,
		sort_info::in, sort_info::out) is det.

rl_sort__handle_output_indexing(BlockId, output_rel(Output, Indexes0)) -->
	{ set__singleton_set(BlockIds, BlockId) },
	{ list__sort_and_remove_dups(Indexes0, Indexes) },
	{ list__map(
		lambda([Index::in, Spec::out] is det,
			Spec = index(Index) - sort_req(definite, BlockIds)),
		Indexes, Specs0) },
	{ map__from_assoc_list(Specs0, Specs) },
	rl_sort__add_relation_sortedness_map(Specs, Output).

:- pred rl_sort__assign_indexing(block_id::in, relation_id::in,
		relation_id::in, sort_info::in, sort_info::out) is det.

rl_sort__assign_indexing(BlockId, Output, Input) -->
	rl_sort__assign_sortedness_and_indexing(index_filter,
		BlockId, Output, Input).

:- pred rl_sort__assign_sortedness(block_id::in, relation_id::in,
		relation_id::in, sort_info::in, sort_info::out) is det.

rl_sort__assign_sortedness(BlockId, Output, Input) -->
	rl_sort__assign_sortedness_and_indexing(sort_filter,
		BlockId, Output, Input).

:- pred rl_sort__unset_relation(relation_id::in, 
		sort_info::in, sort_info::out) is det.

rl_sort__unset_relation(Relation, SortInfo0, SortInfo) :-
	SortInfo0 = sort_info(sortedness(RelMap0, VarMap), VarReqs, Info),
	map__delete(RelMap0, Relation, RelMap),
	SortInfo = sort_info(sortedness(RelMap, VarMap), VarReqs, Info).

%-----------------------------------------------------------------------------%

	% Work out what sorting and indexing is required at the start
	% of a block given the sorting and indexing required at the
	% end of the block.
:- pred rl_sort__needed_block_update(block_id::in, sortedness::in,
	sort_data::in, sort_data::out, var_requests::in,
	var_requests::out, rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__needed_block_update(BlockId, InValue0,
		_SortData0, SortData, VarReqs0, VarReqs, Info0, Info) :-
	rl_opt_info_get_last_block_id(LastBlockId, Info0, Info1),     
	rl_opt_info_get_output_relations(Outputs, Info1, Info2),
	rl_opt_info_get_block(BlockId, Block, Info2, Info3),
	SortInfo0 = sort_info(InValue0, VarReqs0, Info3),
	( BlockId = LastBlockId ->
		% For the last block, the in value is InValue0 (which contains
		% the required sortedness of the memoed relations) plus
		% the required sortedness of the output relations.
		list__foldl(rl_sort__add_call_sortedness(BlockId), Outputs,
			SortInfo0, SortInfo1)
	;
		SortInfo1 = SortInfo0
	),

	Block = block(_, Instrs, _, block_info(LiveAtStart, _)),
	list__reverse(Instrs, RevInstrs),
	list__foldl(rl_sort__instr_needed(BlockId), RevInstrs,
		SortInfo1, sort_info(OutValue0, VarReqs, Info)),
	rl_sort__restrict(OutValue0, LiveAtStart, OutValue),
	SortData = block_data(InValue0, OutValue, unit).

:- pred rl_sort__instr_needed(block_id::in, rl_instruction::in,
		sort_info::in, sort_info::out) is det.

rl_sort__instr_needed(BlockId,
		join(_Output, Input1, Input2, Type, _Exprn) - _) -->
	( 
		{ Type = nested_loop }
	;
		{ Type = semi }
	;
		{ Type = sort_merge(SortSpec1, SortSpec2) },
		rl_sort__add_relation_sortedness(BlockId, sort(SortSpec1),
			Input1),
		rl_sort__add_relation_sortedness(BlockId, sort(SortSpec2),
			Input2)
	;
		{ Type = index(Index, _) },
		rl_sort__add_relation_sortedness(BlockId, index(Index),
			Input2)
	;
		{ Type = cross }
	).
rl_sort__instr_needed(BlockId,
		subtract(_Output, Input1, Input2, Type, _Exprn) - _) -->
	(
		{ Type = nested_loop }
	;
		{ Type = semi }
	;
		{ Type = sort_merge(SortSpec1, SortSpec2) },
		rl_sort__add_relation_sortedness(BlockId, sort(SortSpec1),
			Input1),
		rl_sort__add_relation_sortedness(BlockId, sort(SortSpec2),
			Input2)
	;
		{ Type = index(Index, _) },
		rl_sort__add_relation_sortedness(BlockId, index(Index),
			Input2)
	).
rl_sort__instr_needed(BlockId,
		difference(_Output, Input1, Input2, Type) - _) -->
	{ Type = sort_merge(SortSpec) },
	rl_sort__add_relation_sortedness(BlockId, sort(SortSpec), Input1),
	rl_sort__add_relation_sortedness(BlockId, sort(SortSpec), Input2).

	% XXX interpret projection conditions.
rl_sort__instr_needed(_, project(_, _Input1, _,
		_, _) - _) --> [].
rl_sort__instr_needed(BlockId, union(_Output, Inputs, Type) - _) -->
	{ Type = sort_merge(SortSpec) },
	list__foldl(rl_sort__add_relation_sortedness(BlockId, sort(SortSpec)),
		Inputs).
rl_sort__instr_needed(BlockId, insert(UoOutput, DiInput, _, InsertType, _) - _)
		-->
	( { InsertType = index(Index) } ->
		rl_sort__assign_indexing(BlockId, DiInput, UoOutput),
		rl_sort__add_relation_sortedness(BlockId,
			index(Index), DiInput)
	;
		[]
	).
rl_sort__instr_needed(BlockId,
		union_diff(UoOutput, DiInput, _, _, Index, _) - _) -->
	rl_sort__assign_indexing(BlockId, DiInput, UoOutput),
	rl_sort__add_relation_sortedness(BlockId, index(Index), DiInput).
rl_sort__instr_needed(_BlockId, sort(_Output, _Input, _Attrs) - _) --> [].
rl_sort__instr_needed(BlockId, ref(Output, Input) - _) -->
	rl_sort__assign_sortedness_and_indexing(BlockId, Input, Output).
rl_sort__instr_needed(BlockId, copy(Output, Input) - _) -->
	{ Output = output_rel(OutputRel, _) },
	rl_sort__assign_sortedness(BlockId, Input, OutputRel).
rl_sort__instr_needed(BlockId, make_unique(Output, Input) - _) -->
	{ Output = output_rel(OutputRel, _) },
	rl_sort__assign_sortedness(BlockId, Input, OutputRel).
rl_sort__instr_needed(_BlockId, init(_Output) - _) --> [].
rl_sort__instr_needed(_BlockId, insert_tuple(_, _, _) - _) --> [].
rl_sort__instr_needed(_BlockId, call(_, _Inputs, _Outputs, _) - _) --> [].
rl_sort__instr_needed(BlockId, aggregate(_Output, Input, _, _) - _) -->
	% An aggregate's input is sorted on both attributes.
	rl_sort__add_relation_sortedness(BlockId,
		sort(attributes([0 - ascending, 1 - ascending])), Input).
rl_sort__instr_needed(_BlockId, add_index(_Output) - _) --> [].
rl_sort__instr_needed(_, clear(_) - _) --> [].
rl_sort__instr_needed(_, unset(Relation) - _) -->
	rl_sort__unset_relation(Relation).
rl_sort__instr_needed(_, label(_) - _) --> [].
rl_sort__instr_needed(_, conditional_goto(_, _) - _) --> [].
rl_sort__instr_needed(_, goto(_) - _) --> [].
rl_sort__instr_needed(_, comment - _) --> [].

%-----------------------------------------------------------------------------%

:- pred rl_sort__write_sort_data(sort_data::in, var_requests::in, 
		io__state::di, io__state::uo) is det. 

rl_sort__write_sort_data(block_data(sortedness(InSortData, _),
		sortedness(OutSortData, _), _), _) -->
	io__write_string("in: "),
	map__foldl(rl_sort__write_sort_req_map, InSortData),
	io__nl,
	io__write_string("out: "),
	map__foldl(rl_sort__write_sort_req_map, OutSortData),
	io__nl.

:- pred rl_sort__write_sort_req_map(relation_id::in,
		map(sort_index, sort_req)::in, 
		io__state::di, io__state::uo) is det. 

rl_sort__write_sort_req_map(Rel, SortMap) -->
	io__write_int(Rel),	
	io__write_string(" -> "),
	map__foldl(rl_sort__write_sort_req, SortMap),
	io__nl.

:- pred rl_sort__write_sort_req(sort_index::in, sort_req::in,
		io__state::di, io__state::uo) is det.

rl_sort__write_sort_req(SortIndex, SortReqs) -->
	io__write_string("\t"),
	io__write(SortIndex),
	io__write_string(" - "),
	io__write(SortReqs),
	io__nl.
	
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% Work out what sorting and indexing is available at the end
	% of a block given the sorting and indexing available at the start.
:- pred rl_sort__avail_block_update(block_id::in, sortedness::in,
	sort_data::in, sort_data::out, var_requests::in, var_requests::out,
	rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__avail_block_update(BlockId, InValue0, _SortData0, SortData,
		VarRequests0, VarRequests, Info0, Info) :-
	rl_opt_info_get_first_block_id(FirstBlockId, Info0, Info1),	
	rl_opt_info_get_block(BlockId, Block, Info1, Info2),
	rl_opt_info_get_input_relations(Inputs, Info2, Info3),
	SortInfo0 = sort_info(InValue0, VarRequests0, Info3),
	( BlockId = FirstBlockId ->
		% For the first block, the in value is InValue0 (which contains
		% the required sortedness of the memoed relations) plus
		% the required sortedness of the input relations.
		list__foldl(rl_sort__add_call_sortedness(BlockId), Inputs,
			SortInfo0, SortInfo1)
	;
		SortInfo1 = SortInfo0
	),
	SortInfo1 = sort_info(InValue, _, _),

	Block = block(_, Instrs, _, block_info(_, LiveAtEnd)),
	list__foldl(rl_sort__instr_avail(BlockId), Instrs,
		SortInfo1, sort_info(OutValue0, VarRequests, Info)),
	rl_sort__restrict(OutValue0, LiveAtEnd, OutValue),

	SortData = block_data(InValue, OutValue, unit).

:- pred rl_sort__instr_avail(block_id::in, rl_instruction::in,
		sort_info::in, sort_info::out) is det.

rl_sort__instr_avail(BlockId,
		join(Output, _Input1, _Input2, _Type, _Exprn) - _) -->
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId,
		subtract(Output, _Input1, _Input2, _Type, _Exprn) - _) -->
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId,
		difference(Output, _Input1, _Input2, _Type) - _) -->
	% { Type = sort_merge(SortSpec) },
	% XXX is the output of a difference sorted?
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, project(Output, Input, Goal,
		OtherProjectOutputs, _) - _) -->
	rl_sort__handle_project_sortedness(Input, Output - Goal),
	list__foldl(rl_sort__handle_project_sortedness(Input),
		OtherProjectOutputs),
	{ assoc_list__keys(OtherProjectOutputs, OtherOutputs) },
	list__foldl(rl_sort__handle_output_indexing(BlockId),
		[Output | OtherOutputs]).
rl_sort__instr_avail(BlockId, union(Output, _Inputs, Type) - _) -->
	{ Type = sort_merge(SortSpec) },
	{ Output = output_rel(OutputRel, _) },
	rl_sort__add_relation_sortedness(BlockId, sort(SortSpec), OutputRel),
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, insert(UoOutput, DiInput, _Input, _Type, _) - _)
		-->
	rl_sort__assign_indexing(BlockId, UoOutput, DiInput).
rl_sort__instr_avail(BlockId,
		union_diff(UoOutput, DiInput, _Input1, Diff, _, _) - _) -->
	rl_sort__assign_indexing(BlockId, UoOutput, DiInput),
	rl_sort__handle_output_indexing(BlockId, Diff).
rl_sort__instr_avail(BlockId, sort(Output, _Input, Attrs) - _) -->
	{ Output = output_rel(OutputRel, _) },
	rl_sort__add_relation_sortedness(BlockId,
		sort(attributes(Attrs)), OutputRel),
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, ref(Output, Input) - _) -->
	rl_sort__assign_sortedness_and_indexing(BlockId, Output, Input).
rl_sort__instr_avail(BlockId, copy(Output, Input) - _) -->
	{ Output = output_rel(OutputRel, _) },
	rl_sort__assign_sortedness(BlockId, OutputRel, Input),
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, make_unique(Output, Input) - _) -->
	{ Output = output_rel(OutputRel, _) },
	rl_sort__assign_sortedness(BlockId, OutputRel, Input),
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, init(Output) - _) -->
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, insert_tuple(Output, _, _) - _) -->
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, call(_, _Inputs, Outputs, _) - _) -->
	list__foldl(rl_sort__handle_output_indexing(BlockId), Outputs).
rl_sort__instr_avail(BlockId, aggregate(Output, _Input, _, _) - _) -->
	% An aggregate's output is sorted on both attributes.
	{ Output = output_rel(OutputRel, _) },
	rl_sort__add_relation_sortedness(BlockId,
		sort(attributes([0 - ascending, 1 - ascending])), OutputRel),
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(BlockId, add_index(Output) - _) -->
	rl_sort__handle_output_indexing(BlockId, Output).
rl_sort__instr_avail(_, clear(_) - _) --> [].
rl_sort__instr_avail(_, unset(Relation) - _) -->
	rl_sort__unset_relation(Relation).
rl_sort__instr_avail(_, label(_) - _) --> [].
rl_sort__instr_avail(_, conditional_goto(_, _) - _) --> [].
rl_sort__instr_avail(_, goto(_) - _) --> [].
rl_sort__instr_avail(_, comment - _) --> [].

:- pred rl_sort__handle_project_sortedness(relation_id::in,
	pair(output_rel, rl_goal)::in, sort_info::in, sort_info::out) is det.

rl_sort__handle_project_sortedness(Input, output_rel(Output, _) - Goal) -->
	=(sort_info(sortedness(RelMap0, _VarMap0), _, _)),
	( { map__search(RelMap0, Input, InputSortedness) } ->
		{ map__to_assoc_list(InputSortedness, InputSortednessAL) },
		{ list__filter_map(rl_sort__interpret_project(Goal),
			InputSortednessAL, OutputSortednessAL) },
		{ map__from_assoc_list(OutputSortednessAL, OutputSortedness) },
		rl_sort__add_relation_sortedness_map(OutputSortedness, Output)
	;
		[]
	).

:- pred rl_sort__interpret_project(rl_goal::in, pair(sort_index, sort_req)::in,
		pair(sort_index, sort_req)::out) is semidet.

rl_sort__interpret_project(RLGoal, sort(SortSpec0) - Reqs,
		sort(SortSpec) - Reqs) :-
	RLGoal = rl_goal(_, _, _, _, _, Inputs, Outputs, _, _),	
	Inputs = one_input(InputArgs),
	(
		% A select. 
		Outputs = no,
		SortSpec = SortSpec0
	;
		% A project.
		Outputs = yes(OutputArgs),
		SortSpec0 = attributes(SortAttrs0),

		% Work out the sort specification in terms
		% of the input arguments.
		list__map(
			lambda([AttrDir::in, VarDir::out] is det, (
				AttrDir = Attr - Dir,
				list__index0_det(InputArgs, Attr, Var),
				VarDir = Var - Dir
			)), SortAttrs0, VarAttrs0),

		% Take the longest prefix of the sort specification that
		% is in the output arguments (we could do better here
		% by looking at the goal, since some of the outputs may
		% be equivalent but not named identically to the input).
		list__takewhile(
			lambda([VarDir::in] is semidet, (
				VarDir = Var - _,
				list__member(Var, OutputArgs)
			)), VarAttrs0, VarAttrs, _),
		VarAttrs \= [],

		% Map those output arguments back into argument numbers.
		list__map(
			lambda([VarDir::in, AttrDirs::out] is det, (
				VarDir = Var - Dir,
				rl_sort__all_positions(OutputArgs,
					0, Var, Attrs),
				list__map(lambda([X::in, Y::out] is det, (
					Y = X - Dir
				)), Attrs, AttrDirs)
			)), VarAttrs, SortAttrs1),
		list__condense(SortAttrs1, SortAttrs),
		SortSpec = attributes(SortAttrs)
	).

	% Find all indexes of the variable in the list of variables.
	% XXX possibly should be in list.m.
:- pred rl_sort__all_positions(list(prog_var)::in,
		int::in, prog_var::in, list(int)::out) is det.

rl_sort__all_positions([], _, _, []). 
rl_sort__all_positions([Arg | Args], Index0, Var, Attrs) :-
	Index is Index0 + 1,
	( Arg = Var ->
		Attrs = [Index0 | Attrs1],
		rl_sort__all_positions(Args, Index, Var, Attrs1)
	;
		rl_sort__all_positions(Args, Index, Var, Attrs)
	).

%-----------------------------------------------------------------------------%

:- pred rl_sort__exploit_sorting_and_indexing(sort_data_map::in,
		block_id::in, rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__exploit_sorting_and_indexing(AvailSortMap, BlockId, Info0, Info) :-
	rl_opt_info_get_block(BlockId, Block0, Info0, Info1),
	Block0 = block(Label, Instrs0, EndInstr, BlockInfo),

	map__lookup(AvailSortMap, BlockId, block_data(AvailSorts, _, _)),
	map__init(VarRequests),
	SortInfo0 = sort_info(AvailSorts, VarRequests, Info1),
	
	list__foldl2(rl_sort__specialize_instr(BlockId),
		Instrs0, [], RevInstrs, SortInfo0, sort_info(_, _, Info2)),
	list__reverse(RevInstrs, Instrs),
	Block = block(Label, Instrs, EndInstr, BlockInfo),
	rl_opt_info_set_block(BlockId, Block, Info2, Info).

:- pred rl_sort__specialize_instr(block_id::in, rl_instruction::in,
 	list(rl_instruction)::in, list(rl_instruction)::out,
	sort_info::in, sort_info::out) is det.

rl_sort__specialize_instr(BlockId, Instr0, Instrs0, Instrs) -->
	(
		{ Instr0 = join(Output, Input1, Input2, Type, Exprn)
			- Comment }
	->
		rl_sort__specialize_join(Instr0, Output, Input1, Input2,
			Exprn, Type, Comment, Instrs0, Instrs)
	;
		{ Instr0 = project(Output, Input, Exprn,
			OtherOutputs, Type) - Comment }
	->
		rl_sort__specialize_project(Instr0, Output, Input, Exprn,
			OtherOutputs, Type, Comment, Instrs0, Instrs)
	;
		rl_sort__instr_avail(BlockId, Instr0),
		{ Instrs = [Instr0 | Instrs0] }
	).

%-----------------------------------------------------------------------------%

	% Attempt to use an indexed join algorithm.
:- pred rl_sort__specialize_join(rl_instruction::in, output_rel::in,
	relation_id::in, relation_id::in, rl_goal::in, join_type::in,
	string::in, list(rl_instruction)::in, list(rl_instruction)::out,
	sort_info::in, sort_info::out) is det.

rl_sort__specialize_join(Instr0, Output, Input1, Input2, Exprn,
		_Type, Comment, Instrs0, Instrs,
		SortInfo0, SortInfo) :-
	SortInfo0 = sort_info(Sortedness0, SortVars, RLInfo0),
	Sortedness0 = sortedness(RelSortMap, _),
	rl_opt_info_get_relation_info_map(RelMap, RLInfo0, RLInfo1),
	rl_sort__get_relation_indexes(RelSortMap, RelMap,
		Input1, Input1Indexes, IsBaseRelation1), 
	rl_sort__get_relation_indexes(RelSortMap, RelMap,
		Input2, Input2Indexes, IsBaseRelation2), 

	( Input1Indexes = [], Input2Indexes = [] ->
		% XXX maybe introduce sort-merge joins.
		Instrs = [Instr0 | Instrs0],
		RLInfo = RLInfo1
	;
		rl_opt_info_get_module_info(ModuleInfo, RLInfo1, RLInfo2),
		rl_sort__find_useful_join_indexes(ModuleInfo, Input1Indexes, 
			Exprn, one, IndexRanges1),
		rl_sort__find_useful_join_indexes(ModuleInfo, Input2Indexes, 
			Exprn, two, IndexRanges2),

		% XXX the choice of index here is slightly cheap and nasty
		% when there are multiple possibilities.
		RLInfo = RLInfo2,
		(
			IndexRanges1 = [],
			IndexRanges2 = [],
			Optimize = no,
			SwapInputs = no
		;
			IndexRanges1 = [IndexRange1a | IndexRanges1a],
			IndexRanges2 = [],
			rl_sort__choose_join_index(IndexRanges1a,
				IndexRange1a, IndexRange),
			Optimize = yes(IndexRange),
			SwapInputs = yes
		;
			IndexRanges1 = [],
			IndexRanges2 = [IndexRange2a | IndexRanges2a],
			rl_sort__choose_join_index(IndexRanges2a,
				IndexRange2a, IndexRange),
			Optimize = yes(IndexRange),
			SwapInputs = no
		;
			IndexRanges1 = [IndexRange1a | IndexRanges1a],
			IndexRanges2 = [IndexRange2a | IndexRanges2a],
			rl_sort__choose_join_index(IndexRanges1a,
				IndexRange1a, BestIndexRange1),
			rl_sort__choose_join_index(IndexRanges2a,
				IndexRange2a, BestIndexRange2),

			% Prefer an index on a base relation, since they
			% are more likely to be large.
			% (XXX this isn't necessarily correct).
			(
				IsBaseRelation1 = yes,
				IsBaseRelation2 = no
			->
				SwapInputs = yes,
				Optimize = yes(BestIndexRange1)
			;
				IsBaseRelation1 = no,
				IsBaseRelation2 = yes
			->
				SwapInputs = no,
				Optimize = yes(BestIndexRange2)
			;
				% In this case, we should generate conditional
				% code to index the largest relation.
				SwapInputs = no,
				Optimize = yes(BestIndexRange2)
			)
		),
		% XXX handle multiple key ranges.
		( Optimize = yes(Index - [KeyRange]) ->
			JoinType = index(Index, KeyRange),
			( SwapInputs = yes ->
				rl__swap_goal_inputs(Exprn, Exprn1),
				JoinInput1 = Input2,
				JoinInput2 = Input1
			;
				Exprn1 = Exprn,
				JoinInput1 = Input1,
				JoinInput2 = Input2
			),
			JoinInstr = join(Output, JoinInput1, JoinInput2,
				JoinType, Exprn1) - Comment
		;
			JoinInstr = Instr0
		),
		Instrs = [JoinInstr | Instrs0]
	),
	SortInfo = sort_info(Sortedness0, SortVars, RLInfo).

:- pred rl_sort__find_useful_join_indexes(module_info::in,
		list(index_spec)::in, rl_goal::in, tuple_num::in,
		index_ranges::out) is det.

rl_sort__find_useful_join_indexes(ModuleInfo, Indexes,
		Goal, TupleNum, IndexRanges) :-
	Goal = rl_goal(_, _, VarTypes, _, _, Inputs, _, _, VarBounds),
	( VarBounds = [] ->
		IndexRanges = []
	;
		list__filter_map(
		    lambda([Index::in, ThisIndexRanges::out] is semidet, (
			Inputs = two_inputs(Args1, Args2),
			( 
				TupleNum = one,
				rl_key__get_join_key_ranges(ModuleInfo,
					VarTypes, Args2, Args1, Index,
					VarBounds, Ranges)
			;	
				TupleNum = two,
				rl_key__get_join_key_ranges(ModuleInfo,
					VarTypes, Args1, Args2, Index,
					VarBounds, Ranges)
			),
			ThisIndexRanges = Index - Ranges
		    )), Indexes, IndexRanges)
	).

:- type index_ranges == list(index_range).
:- type index_range == pair(index_spec, list(key_range)).

	% XXX make a more intelligent choice here.
:- pred rl_sort__choose_join_index(index_ranges::in,
		index_range::in, index_range::out) is det.

rl_sort__choose_join_index(_IndexRanges, IndexRange, IndexRange).

%-----------------------------------------------------------------------------%

	% Work out which index could be used for a project.
:- pred rl_sort__specialize_project(rl_instruction::in, output_rel::in,
	relation_id::in, rl_goal::in, assoc_list(output_rel, rl_goal)::in,
	project_type::in, string::in, list(rl_instruction)::in,
	list(rl_instruction)::out, sort_info::in, sort_info::out) is det.
		
rl_sort__specialize_project(Instr0, OutputRel, Input, Exprn, ProjOutputs0,
		_Type, Comment, Instrs0, Instrs, SortInfo0, SortInfo) :-
	SortInfo0 = sort_info(Sortedness0, SortVars, RLInfo0),
	Sortedness0 = sortedness(RelSortMap, _),
	rl_opt_info_get_relation_info_map(RelMap, RLInfo0, RLInfo1),
	rl_sort__get_relation_indexes(RelSortMap, RelMap,
		Input, Indexes, _), 
	( Indexes = [] ->
		Instrs = [Instr0 | Instrs0],
		RLInfo = RLInfo1
	;
		ProjOutputs = [OutputRel - Exprn | ProjOutputs0],
		rl_opt_info_get_module_info(ModuleInfo, RLInfo1, RLInfo2),
		list__map(rl_sort__find_useful_project_indexes(ModuleInfo,
			Indexes), ProjOutputs, ProjOutputIndexes),

		% Partition out those expressions for which there
		% are no suitable indexes.
		list__filter(lambda([ProjOutput::in] is semidet, 
			ProjOutput = proj_output(_, _, [])),
			ProjOutputIndexes, NoIndexOutputs0, IndexOutputs),
		( IndexOutputs = [] ->
			Instrs = [Instr0 | Instrs0],
			RLInfo = RLInfo2
		;
			rl_sort__partition_project_outputs(IndexOutputs,
				Partitions0),
			( NoIndexOutputs0 = [] ->
				Partitions = Partitions0
			;
				list__map(
				    lambda([POutput::in, PRel::out] is det,  (
					POutput = proj_output(ORel, Goal, _),
					PRel = ORel - Goal
				    )), NoIndexOutputs0, NoIndexOutputs),	
				Partition = NoIndexOutputs - no,
				Partitions = [Partition | Partitions0]
			),
			list__map(rl_sort__generate_project(Input, Comment),
				Partitions, Projections),
			list__append(Projections, Instrs0, Instrs),
			RLInfo = RLInfo2
		)
	),
	SortInfo = sort_info(Sortedness0, SortVars, RLInfo).

:- type proj_output
	---> proj_output(
		output_rel,
		rl_goal,
		assoc_list(index_spec, list(key_range))
	).

:- type assigned_project_output ==
		pair(assoc_list(output_rel, rl_goal),
			maybe(pair(index_spec, list(key_range)))).

:- pred rl_sort__find_useful_project_indexes(module_info::in,
		list(index_spec)::in, pair(output_rel, rl_goal)::in,
		proj_output::out) is det.

rl_sort__find_useful_project_indexes(ModuleInfo, Indexes, OutputRel - Goal,
		proj_output(OutputRel, Goal, IndexRanges)) :-
	Goal = rl_goal(_, _, VarTypes, _, _, Inputs, _, _, VarBounds),
	( VarBounds = [] ->
		IndexRanges = []
	;
		list__filter_map(
		    lambda([Index::in, ThisIndexRanges::out] is semidet, (
			Inputs = one_input(Args),
			rl_key__get_select_key_ranges(ModuleInfo, VarTypes,
				Args, Index, VarBounds, Ranges),
			ThisIndexRanges = Index - Ranges
		    )), Indexes, IndexRanges)
	).

	% Find the set of indexes which results in the smallest
	% number of passes over the input.
	% XXX currently this is _very_ non-optimal.
:- pred rl_sort__partition_project_outputs(list(proj_output)::in,
	list(assigned_project_output)::out) is det.

rl_sort__partition_project_outputs([], []).
rl_sort__partition_project_outputs([Output | Outputs],
		[Partition | Partitions]) :-
	( Output = proj_output(OutputRel0, Goal, [IndexRange | _]) ->
		OutputRel = OutputRel0,
		IndexRange = Index - KeyRanges,
		Partition = [OutputRel - Goal] - yes(Index - KeyRanges)
	;
		error("rl_sort__partition_project_outputs")	
	),
	rl_sort__partition_project_outputs(Outputs, Partitions).

:- pred rl_sort__generate_project(relation_id::in, string::in,
	assigned_project_output::in, rl_instruction::out) is det.

rl_sort__generate_project(Input, Comment, Outputs - MaybeIndex, Instr) :-
	( Outputs = [FirstOutput - FirstExprn | OtherOutputs] ->
		% XXX handle multiple key ranges - at the moment you have
		% to do each key range as a separate operation and then
		% union together the results. It would be much better
		% if all the key ranges could be applied as part of the
		% same operation -- for joins overlapping key ranges could
		% then be merged at runtime.
		(
			MaybeIndex = yes(Index - KeyRanges),
			KeyRanges = [KeyRange]
		->
			Type = index(Index, KeyRange)
		;
			Type = filter
		),
		Instr = project(FirstOutput, Input, FirstExprn,
			OtherOutputs, Type) - Comment
	;
		error("rl_sort__generate_project")
	).

%-----------------------------------------------------------------------------%

	% Work out which indexes a relation definitely has at this
	% point in the code, also returning whether the relation is
	% a base relation.
:- pred rl_sort__get_relation_indexes(relation_sort_map::in,
	relation_info_map::in, relation_id::in, list(index_spec)::out,
	bool::out) is det.
				
rl_sort__get_relation_indexes(RelSortMap, RelMap,
		Rel, Indexes, IsBaseRelation) :-
	map__lookup(RelMap, Rel, RelInfo),
	( RelInfo = relation_info(permanent(_), _, Indexes0, _) ->
		Indexes = Indexes0,
		IsBaseRelation = yes
	;
		( map__search(RelSortMap, Rel, Specs0) ->
			map__to_assoc_list(Specs0, SpecsAL),
			list__filter_map(
				lambda([SpecPair::in, Index::out] is semidet, (
					SpecPair = index(Index)
						- sort_req(definite, _)
				)), SpecsAL, Indexes)
		;
			Indexes = []
		),
		IsBaseRelation = no
	).

%-----------------------------------------------------------------------------%

	% Remove unnecessary indexing and sorting operations.
:- pred rl_sort__remove_useless_ops(sort_data_map::in, block_id::in, 
		rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__remove_useless_ops(NeededSortMap, BlockId, Info0, Info) :-
	rl_opt_info_get_block(BlockId, Block0, Info0, Info1),
	Block0 = block(Label, Instrs0, EndInstr, BlockInfo),

	list__reverse(Instrs0, RevInstrs0),
	map__lookup(NeededSortMap, BlockId, block_data(NeededSorts, _, _)),
	map__init(VarRequests),
	SortInfo0 = sort_info(NeededSorts, VarRequests, Info1),
	
	list__foldl2(rl_sort__remove_useless_ops_instr(BlockId),
		RevInstrs0, [], Instrs, SortInfo0, sort_info(_, _, Info2)),
	Block = block(Label, Instrs, EndInstr, BlockInfo),
	rl_opt_info_set_block(BlockId, Block, Info2, Info).

:- pred rl_sort__remove_useless_ops_instr(block_id::in, 
	rl_instruction::in, list(rl_instruction)::in,
	list(rl_instruction)::out, sort_info::in, sort_info::out) is det.

rl_sort__remove_useless_ops_instr(BlockId, Instr, Instrs0, Instrs) -->
	=(sort_info(sortedness(RelSortMap, _), _, _)),
	( { Instr = add_index(OutputRel0) - Comm } ->
		{ rl_sort__map_output_rel(RelSortMap, rl_sort__map_spec,
			OutputRel0, OutputRel) },
		{ OutputRel = output_rel(Relation, NeededIndexes) },
		{ NeededIndexes = [] ->
			Instrs = Instrs0
		;
			Instrs = [add_index(output_rel(Relation, 
				NeededIndexes)) - Comm | Instrs0]
		}
	; { Instr = sort(Output0, Input, SortSpec) - Comm } ->
		{ rl_sort__map_output_rel(RelSortMap, rl_sort__map_spec,
			Output0, Output) },
		{ Output = output_rel(OutputRel, _) },
		{ map__search(RelSortMap, OutputRel, NeededSpecs) ->
			(
				map__contains(NeededSpecs,
					sort(attributes(SortSpec)))
			->
				SpecNeeded = yes
			;
			    	SpecNeeded = no
			)
		;
			SpecNeeded = no
		},
		(
			{ SpecNeeded = no },
			list__foldl2(
			    rl_sort__remove_useless_ops_instr(BlockId),
				[add_index(Output) - Comm,
				ref(OutputRel, Input) - Comm],
				Instrs0, Instrs)
		;
			{ SpecNeeded = yes },
			{ rl_sort__map_spec(SortSpec, SortSpec1) },
			{ Instrs = [sort(Output, Input, SortSpec1) - Comm |
					Instrs0] }
		)
	;
		{ rl_sort__map_sort_and_index_specs(
			rl_sort__map_output_rel(RelSortMap, rl_sort__map_spec),
			rl_sort__map_spec, rl_sort__map_spec,
			Instr, Instr1) },
		{ Instrs = [Instr1 | Instrs0] }
	),
	rl_sort__instr_needed(BlockId, Instr).

	% Eventually this will need to instantiate sort variables.
:- pred rl_sort__map_spec(T::in, T::out) is det.

rl_sort__map_spec(Spec, Spec).

:- pred rl_sort__map_output_rel(relation_sort_map::in,
		pred(index_spec, index_spec)::(pred(in, out) is det),
		output_rel::in, output_rel::out) is det.

rl_sort__map_output_rel(RelSortMap, MapIndex, output_rel(Output, Indexes0),
		output_rel(Output, Indexes)) :-
	( map__search(RelSortMap, Output, NeededSpecs) ->
		list__filter(rl_sort__index_is_needed(NeededSpecs),
			Indexes0, Indexes1),
		list__map(MapIndex, Indexes1, Indexes)
	;
		Indexes = []
	).

:- pred rl_sort__index_is_needed(map(sort_index, _T)::in,
		index_spec::in) is semidet.

rl_sort__index_is_needed(NeededMap, Index) :-
	map__contains(NeededMap, index(Index)).


	% Update sort and index instruction specifiers for an instruction,
	% binding sort variables and removing unneeded index specifiers.
:- pred rl_sort__map_sort_and_index_specs(
		pred(output_rel, output_rel)::(pred(in, out) is det),
		pred(index_spec, index_spec)::(pred(in, out) is det),
		pred(sort_spec, sort_spec)::(pred(in, out) is det),
		rl_instruction::in, rl_instruction::out) is det.

rl_sort__map_sort_and_index_specs(OutputPred, IndexPred, SortPred,
		join(Output0, B, C, Type0, E) - F,
		join(Output, B, C, Type, E) - F) :-
	call(OutputPred, Output0, Output),
	( Type0 = sort_merge(Sort1a, Sort2a) ->
		call(SortPred, Sort1a, Sort1),
		call(SortPred, Sort2a, Sort2),
		Type = sort_merge(Sort1, Sort2)
	; Type0 = index(Index0, Range) ->
		call(IndexPred, Index0, Index),
		Type = index(Index, Range)
	;
		Type = Type0		
	).
rl_sort__map_sort_and_index_specs(OutputPred, IndexPred, SortPred,
		subtract(Output0, B, C, Type0, E) - F,
		subtract(Output, B, C, Type, E) - F) :-
	call(OutputPred, Output0, Output),
	( Type0 = sort_merge(Sort1a, Sort2a) ->
		call(SortPred, Sort1a, Sort1),
		call(SortPred, Sort2a, Sort2),
		Type = sort_merge(Sort1, Sort2)
	; Type0 = index(Index0, Range) ->
		call(IndexPred, Index0, Index),
		Type = index(Index, Range)
	;
		Type = Type0		
	).
rl_sort__map_sort_and_index_specs(OutputPred, _, SortPred,
		difference(Output0, B, C, Type0) - E,
		difference(Output, B, C, Type) - E) :-
	call(OutputPred, Output0, Output),
	Type0 = sort_merge(SortSpec0),
	call(SortPred, SortSpec0, SortSpec),
	Type = sort_merge(SortSpec).
rl_sort__map_sort_and_index_specs(OutputPred, IndexPred, _,
		project(Output0,
			B, C, ProjectOutputs0, Type0) - F,
		project(Output,
			B, C, ProjectOutputs, Type) - F) :-
	call(OutputPred, Output0, Output),
	list__map(lambda([ProjOutput0::in, ProjOutput::out] is det, (
			ProjOutput0 = OutputRel0 - Expr,
			call(OutputPred, OutputRel0, OutputRel),
			ProjOutput = OutputRel - Expr
		)), ProjectOutputs0, ProjectOutputs),
	(
		Type0 = index(Index0, Range),
		call(IndexPred, Index0, Index),
		Type = index(Index, Range)
	;
		Type0 = filter,
		Type = filter
	).
rl_sort__map_sort_and_index_specs(OutputPred, _IndexPred, SortPred, 
		union(Output0, Inputs, Type0) - Comm,
		union(Output, Inputs, Type) - Comm) :-
	call(OutputPred, Output0, Output),
	Type0 = sort_merge(SortSpec0),
	call(SortPred, SortSpec0, SortSpec),
	Type = sort_merge(SortSpec).
rl_sort__map_sort_and_index_specs(OutputPred, IndexPred, _,
		insert(A, B, C, Type0, MaybeCopy0) - F,
		insert(A, B, C, Type, MaybeCopy) - F) :-
	(
		Type0 = append,
		Type = append
	;
		Type0 = index(Index0),
		call(IndexPred, Index0, Index),
		Type = index(Index)
	),
	(
		MaybeCopy0 = yes(Copy0),
		call(OutputPred, Copy0, Copy),
		MaybeCopy = yes(Copy)
	;
		MaybeCopy0 = no,
		MaybeCopy = no
	).
rl_sort__map_sort_and_index_specs(OutputPred, IndexPred, _,
		union_diff(A, B, C, Diff0, Index0, MaybeCopy0) - G,
		union_diff(A, B, C, Diff, Index, MaybeCopy) - G) :-
	call(IndexPred, Index0, Index),
	call(OutputPred, Diff0, Diff),
	(
		MaybeCopy0 = yes(Copy0),
		call(OutputPred, Copy0, Copy),
		MaybeCopy = yes(Copy)
	;
		MaybeCopy0 = no,
		MaybeCopy = no
	).
rl_sort__map_sort_and_index_specs(OutputPred, _, SortPred,
		sort(Output0, B, Attrs0) - D,
		sort(Output, B, Attrs) - D) :-
	call(OutputPred, Output0, Output),
	call(SortPred, attributes(Attrs0), Spec), 
	( Spec = attributes(Attrs1) ->
		Attrs = Attrs1
	;
		error("rl_sort__map_sort_and_index_specs: weird result")
	).	
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = ref(_, _) - _.
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		copy(Output0, Input) - Comm,
		copy(Output, Input) - Comm) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		make_unique(Output0, Input) - Comm,
		make_unique(Output, Input) - Comm) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		init(Output0) - Comm,
		init(Output) - Comm) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		insert_tuple(Output0, B, C) - D,
		insert_tuple(Output, B, C) - D) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		call(A, B, Outputs0, D) - E,
		call(A, B, Outputs, D) - E) :-
	list__map(OutputPred, Outputs0, Outputs).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		aggregate(Output0, B, C, D) - E,
		aggregate(Output, B, C, D) - E) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(OutputPred, _, _,
		add_index(Output0) - Comm,
		add_index(Output) - Comm) :-
	call(OutputPred, Output0, Output).
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = clear(_) - _.
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = unset(_) - _.
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = label(_) - _.
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = conditional_goto(_, _) - _.
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = goto(_) - _.
rl_sort__map_sort_and_index_specs(_, _, _, Instr, Instr) :-
	Instr = comment - _.

%-----------------------------------------------------------------------------%
/*
	% Beyond this point is junk at the moment.

	% Do an assignment of sort specifiers to each sort variable.
:- pred rl_sort__assign_sort_vars(sort_data_map::in, var_requests::in,
	sort_data_map::in, var_requests::in, map(int, sort_index)::out,
	rl_opt_info::in, rl_opt_info::out) is det.

rl_sort__assign_sort_vars(_AvailData0, AvailRequests0, _NeededData0,
		NeededRequests, VarBindings) -->
	{
	map__keys(AvailRequests, VarsList0),
	map__keys(NeededRequests, VarsList1),
	set__sorted_list_to_set(VarsList0, Vars0),
	set__sorted_list_to_set(VarsList1, Vars1),
	set__union(Vars0, Vars1, Vars),

	map__init(VarBindings0), 

	% Find out which sort vars can be allocated based on
	% available sortedness.
	rl_sort__single_request_vars(AvailRequests0,
		VarBindings0, VarBindings1),
	rl_sort__bind_vars(AvailRequests0, VarBindings1, AvailRequests),

	map__keys(VarBindings1, BoundVars1),
	set__delete_list(Vars, BoundVars1, UnboundVars1)
	},
	{ set__empty(UnboundVars1) ->
		VarBindings = VarBindings0
	;
		% Find out which sort vars can be allocated based on
		% needed sortedness intersecting with available sortedness.
		rl_sort__intersect_requests(AvailRequests, NeededRequests,
			IntersectedRequests),

		rl_sort__single_request_vars(IntersectedRequests,
			VarBindings1, VarBindings)

		% If there's anything left unbound, just pick one of the
		% available sortednesses. XXX try all with cost measurement
		% to pick the best.
	}.

	% Find all sort variables which have only one requested sortedness.
:- pred rl_sort__single_request_vars(var_requests::in,
		map(int, sort_index)::in,
		map(int, sort_index)::out) is det.

rl_sort__single_request_vars(Requests0, SingleVars0, SingleVars) :-
	IsSingleBindingVar =
		lambda([Var::in, Reqs0::in, Single0::in, Single::out] is det, (
			set__to_sorted_list(Reqs0, Reqs1),
			(
				\+ map__contains(Single0, Var),
				list__filter(lambda([Req::in] is semidet, (
						\+ Req = sort_var(Var) - _
					)), Reqs1, [Request]),
				Request = attributes(_) - _
			->
				map__det_insert(Single0, Var, Request, Single)
			;
				Single = Single0
			)
		)),
	map__foldl(IsSingleBindingVar, Requests0, SingleVars0, SingleVars).

:- pred rl_sort__intersect_requests(var_requests::in,
		var_requests::in, var_requests::out) is det.

rl_sort__intersect_requests(Requests1, Requests2, Intersection) :-
	IntersectBindings =
		lambda([Key::in, Value0::in, Inter0::in, Inter::out] is det, (
			( map__search(Inter0, Key, Value1) ->
				set__intersect(Value0, Value1, Value),
				map__det_update(Inter0, Key, Value, Inter)
			;
				Inter = Inter0
			))),
	map__foldl(IntersectBindings, Requests1, Requests2, Intersection).
*/

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
