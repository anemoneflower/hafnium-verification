(*
 * Copyright 2019 Jade Philipoom
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *)

Require Import Coq.Arith.PeanoNat.
Require Import Coq.NArith.BinNat.
Require Import Coq.Lists.List.
Require Import Hafnium.AbstractModel.
Require Import Hafnium.Concrete.State.
Require Import Hafnium.Concrete.Datatypes.
Require Import Hafnium.Concrete.Notations.
Require Import Hafnium.Concrete.PointerLocations.
Require Import Hafnium.Util.List.
Require Import Hafnium.Util.Tactics.
Require Import Hafnium.Concrete.Assumptions.Addr.
Require Import Hafnium.Concrete.Assumptions.ArchMM.
Require Import Hafnium.Concrete.Assumptions.Constants.
Require Import Hafnium.Concrete.Assumptions.Datatypes.
Require Import Hafnium.Concrete.Assumptions.Mpool.
Require Import Hafnium.Concrete.Assumptions.PageTables.
Require Import Hafnium.Concrete.MM.Datatypes.

(*** This file contains correctness proofs about the relationship between
     concrete and abstract states. ***)

Section Proofs.
  Context {ap : @abstract_state_parameters paddr_t nat}
          {cp : concrete_params} {cp_valid : params_valid}.

  Local Notation has_location deref :=
   (has_location deref (map vm_ptable vms) hafnium_ptable).
  Local Notation locations_exclusive deref :=
   (locations_exclusive deref (map vm_ptable vms) hafnium_ptable).

  (* if two concrete states are equivalent and an abstract state represents one
     of them, then it also represents the other. *)
  Lemma represents_proper abst conc conc' :
    (forall ptr, conc.(ptable_deref) ptr = conc'.(ptable_deref) ptr) ->
    (conc.(api_page_pool) = conc'.(api_page_pool)) ->
    represents abst conc ->
    represents abst conc'.
  Admitted.

  (* if two abstract states are equivalent and one represents a concrete state,
     then the other also represents that concrete state. *)
  Lemma represents_proper_abstr abst abst' conc :
    abstract_state_equiv abst abst' ->
    represents abst conc ->
    represents abst' conc.
  Admitted.

  (* [represents] includes [is_valid] as one of its conditions *)
  Lemma represents_valid_concrete conc : (exists abst, represents abst conc) -> is_valid conc.
  Proof. cbv [represents]; basics; auto. Qed.
  Hint Resolve represents_valid_concrete.

  (* [abstract_state_equiv] is reflexive *)
  Lemma abstract_state_equiv_refl abst : abstract_state_equiv abst abst.
  Proof. cbv [abstract_state_equiv]. solver. Qed.
  Hint Resolve abstract_state_equiv_refl.

  (* [abstract_state_equiv] is transitive *)
  Lemma abstract_state_equiv_trans abst1 abst2 abst3 :
    abstract_state_equiv abst1 abst2 ->
    abstract_state_equiv abst2 abst3 ->
    abstract_state_equiv abst1 abst3.
  Proof.
    cbv [abstract_state_equiv].
    basics; try solver.
    match goal with
    | H : context [_ <-> _] |- _ => rewrite H; solver
    end.
  Qed.

  (* if the new table is the same as the old, abstract state doesn't change *)
  Lemma reassign_pointer_noop_represents conc ptr t abst :
    conc.(ptable_deref) ptr = t ->
    represents abst conc <->
    represents abst (conc.(reassign_pointer) ptr t).
  Proof.
    repeat match goal with
           | _ => progress basics
           | _ => progress cbn [reassign_pointer ptable_deref]
           | _ => progress cbv [update_deref]
           | |- _ <-> _ => split
           | _ => break_match
           | _ => solver
           | _ => eapply represents_proper;
                    [ | | solve[eauto] ]; eauto; [ ]
           end.
  Qed.

  Fixpoint pointer_in_table
             (deref : ptable_pointer -> mm_page_table) (ptr : ptable_pointer)
             (t : mm_page_table) (level : nat) : Prop :=
    match level with
    | 0 => False
    | S level' =>
      Exists
        (fun pte =>
           if arch_mm_pte_is_table pte level
           then
             let next_t_ptr :=
                 ptable_pointer_from_address (arch_mm_table_from_pte pte level) in
             if ptable_pointer_eq_dec ptr next_t_ptr
             then True
             else pointer_in_table deref ptr (deref next_t_ptr) level'
           else False)
        t.(entries)
    end.

  Definition abstract_change_attrs (abst : abstract_state)
             (a : paddr_t) (e : entity_id) (owned valid : bool) :=
    let eq_dec := @entity_id_eq_dec _ Nat.eq_dec in
    {|
      accessible_by :=
        (fun a' =>
           let prev := abst.(accessible_by) a' in
           if paddr_t_eq_dec a a'
           then if valid
                then nodup eq_dec (e :: prev)
                else remove eq_dec e prev
          else prev);
      owned_by :=
        (fun a' =>
           let prev := abst.(owned_by) a' in
           if paddr_t_eq_dec a a'
           then if owned
                then nodup eq_dec (e :: prev)
                else remove eq_dec e prev
           else prev)
    |}.

  (* indices_from_address starts with the index of the root table in the list of
     root tables (0 if there's only one) and then gives the index in the table at
     [max_level]. The length of this sequence of indices is therefore
     [max_level + 2], because it's [0..(max_level + 1)] *inclusive*. *)
  Definition indices_from_address (a : uintpaddr_t) (stage : Stage) : list nat :=
    map (fun lvl => get_index stage lvl a) (rev (seq 0 (S (S (max_level stage))))).

  Definition address_matches_indices (a : uintpaddr_t) (idxs : list nat) (stage : Stage) : Prop :=
    firstn (length idxs) (indices_from_address a stage) = idxs.

  Definition address_matches_indices_bool (a : uintpaddr_t) (idxs : list nat) (stage : Stage) : bool :=
    forallb (fun '(x,y) => x =? y) (combine (indices_from_address a stage) idxs).

  Definition addresses_under_pointer_in_range
             (deref : ptable_pointer -> mm_page_table)
             (ptr : ptable_pointer) (root_ptable : mm_ptable)
             (begin end_ : uintvaddr_t) (stage : Stage) : list paddr_t :=
    let vrange := map N.of_nat (seq (N.to_nat begin) (N.to_nat (end_ - begin))) in
    let prange := map (fun va => pa_from_va (va_init va)) vrange in
    let paths := index_sequences_to_pointer deref ptr root_ptable stage in
    let path := hd nil paths in (* expects at most one sequence -- prove by locations_exclusive *)
    filter
      (fun a => address_matches_indices_bool (pa_addr a) path stage) prange.

  Definition abstract_reassign_pointer_for_entity
             (abst : abstract_state) (conc : concrete_state)
             (ptr : ptable_pointer) (owned valid : bool)
             (e : entity_id) (root_ptable : mm_ptable)
             (begin end_ : uintvaddr_t) : abstract_state :=
    let stage := match e with
                 | inl _ => Stage2
                 | inr _ => Stage1
                 end in
    fold_right
      (fun pa abst =>
         abstract_change_attrs abst pa e owned valid)
      abst
      (addresses_under_pointer_in_range
         conc.(ptable_deref) ptr root_ptable begin end_ stage).

  Definition owned_from_attrs (attrs : attributes) (stage : Stage) : bool :=
    match stage with
    | Stage1 =>
      let mode := arch_mm_stage1_attrs_to_mode attrs in
      let unowned := ((mode & MM_MODE_UNOWNED) != 0)%N in
      negb unowned
    | Stage2 =>
      let mode := arch_mm_stage2_attrs_to_mode attrs in
      let unowned := ((mode & MM_MODE_UNOWNED) != 0)%N in
      negb unowned
    end.

  Definition valid_from_attrs (attrs : attributes) (stage : Stage) : bool :=
    match stage with
    | Stage1 =>
      let mode := arch_mm_stage1_attrs_to_mode attrs in
      let invalid := ((mode & MM_MODE_INVALID) != 0)%N in
      negb invalid
    | Stage2 =>
      let mode := arch_mm_stage2_attrs_to_mode attrs in
      let invalid := ((mode & MM_MODE_INVALID) != 0)%N in
      negb invalid
    end.

  (* Update the abstract state to make everything under the given pointer have
     the provided new owned/valid bits. *)
  Definition abstract_reassign_pointer
             (abst : abstract_state) (conc : concrete_state)
             (ptr : ptable_pointer) (attrs : attributes)
             (begin end_ : uintvaddr_t) : abstract_state :=
    (* first, get the owned/valid bits *)
    let s1_owned := owned_from_attrs attrs Stage1 in
    let s2_owned := owned_from_attrs attrs Stage2 in
    let s1_valid := valid_from_attrs attrs Stage1 in
    let s2_valid := valid_from_attrs attrs Stage2 in

    (* update the state with regard to Hafnium *)
    let abst :=
        abstract_reassign_pointer_for_entity
          abst conc ptr s1_owned s1_valid (inr hid) hafnium_ptable begin end_ in

    (* update the state with regard to each VM *)
    fold_right
      (fun (v : vm) (abst : abstract_state) =>
         abstract_reassign_pointer_for_entity
           abst conc ptr s2_owned s2_valid (inl v.(vm_id)) (vm_ptable v)
           begin end_)
      abst
      vms.

  Definition has_uniform_attrs
             (ptable_deref : ptable_pointer -> mm_page_table)
             (table_loc : list nat)
             (t : mm_page_table) (level : nat) (attrs : attributes)
             (begin end_ : uintvaddr_t) (stage : Stage) : Prop :=
    forall (a : uintvaddr_t) (pte : pte_t),
      address_matches_indices (pa_from_va (va_init a)).(pa_addr) table_loc stage ->
      (begin <= a < end_)%N ->
      level <= max_level stage ->
      page_lookup' ptable_deref a t level stage = Some pte ->
      forall lvl, arch_mm_pte_attrs pte lvl = attrs.

  Definition attrs_outside_range_unchanged
             (ptable_deref : ptable_pointer -> mm_page_table)
             (table_loc : list nat)
             (t_orig t : mm_page_table) (level : nat) (attrs : attributes)
             (begin end_ : uintvaddr_t) (stage : Stage) : Prop :=
    forall (a : uintvaddr_t) (pte : pte_t),
      address_matches_indices (pa_from_va (va_init a)).(pa_addr) table_loc stage ->
      (a < begin \/ end_ <= a)%N ->
      level <= max_level stage ->
      page_lookup' ptable_deref a t level stage = Some pte ->
      (exists pte_orig,
          page_lookup' ptable_deref a t_orig level stage = Some pte_orig
          /\ forall lvl, arch_mm_pte_attrs pte lvl = arch_mm_pte_attrs pte_orig lvl). 

  Definition attrs_changed_in_range
             (ptable_deref : ptable_pointer -> mm_page_table)
             (table_loc : list nat)
             (t_orig t : mm_page_table) (level : nat) (attrs : attributes)
             (begin end_ : uintvaddr_t) (stage : Stage) : Prop :=
    has_uniform_attrs ptable_deref table_loc t level attrs begin end_ stage
    /\ attrs_outside_range_unchanged
         ptable_deref table_loc t_orig t level attrs begin end_ stage.

  Definition has_location_in_state conc ptr idxs : Prop :=
    exists root_ptable,
      has_location (ptable_deref conc) (api_page_pool conc) ptr
                   (table_loc conc.(api_page_pool) root_ptable idxs).

  Definition root_ptable_matches_stage root_ptable stage : Prop :=
    match stage with
    | Stage1 => root_ptable = hafnium_ptable
    | Stage2 => In root_ptable (map vm_ptable vms)
    end.

  (* gives the new [accessible_by] value of an address under an abstract state
     with a pointer reassigned, assuming the pointer is in a VM's page table *)
  Lemma accessible_by_abstract_reassign_pointer_stage2
        abst conc ptr attrs begin end_ (a : paddr_t) v ppool :
    (* v is in the vms list *)
    In v vms ->
    (* ptr is located under v's root ptable *)
    (exists idxs,
        has_location
          (ptable_deref conc) ppool ptr
          (table_loc ppool (vm_ptable v) idxs)) ->
    (* ptr is not located anywhere else *)
    locations_exclusive conc.(ptable_deref) ppool ->
    (* list of addresses that changed *)
    let changed_addrs :=
        addresses_under_pointer_in_range
          (ptable_deref conc) ptr (vm_ptable v) begin end_ Stage2 in
    (* new abstract state *)
    let new_abst := 
        abstract_reassign_pointer abst conc ptr attrs begin end_ in
    forall e : entity_id,
      In e (accessible_by new_abst a) <->
      if (in_dec paddr_t_eq_dec a changed_addrs)
      then
        if valid_from_attrs attrs Stage2
        then e = inl (vm_id v) \/ In e (accessible_by abst a)
        else e <> inl (vm_id v) /\ In e (accessible_by abst a)
      else In e (accessible_by abst a).
  Admitted. (* TODO *)

  (* gives the new [accessible_by] value of an address under an abstract state
     with a pointer reassigned, assuming the pointer is in hafnium's table *)
  Lemma accessible_by_abstract_reassign_pointer_stage1
        abst conc ptr attrs begin end_ (a : paddr_t) ppool :
    (* ptr is located under hafnium's root ptable *)
    (exists idxs,
        has_location
          (ptable_deref conc) ppool ptr
          (table_loc ppool hafnium_ptable idxs)) ->
    (* ptr is not located anywhere else *)
    locations_exclusive conc.(ptable_deref) ppool ->
    (* list of addresses that changed *)
    let changed_addrs :=
        addresses_under_pointer_in_range
          (ptable_deref conc) ptr hafnium_ptable begin end_ Stage1 in
    (* new abstract state *)
    let new_abst := 
        abstract_reassign_pointer abst conc ptr attrs begin end_ in
    forall e : entity_id,
      In e (accessible_by new_abst a) <->
      if (in_dec paddr_t_eq_dec a changed_addrs)
      then
        if valid_from_attrs attrs Stage1
        then e = inr hid \/ In e (accessible_by abst a)
        else e <> inr hid /\ In e (accessible_by abst a)
      else In e (accessible_by abst a).
  Admitted. (* TODO *)

  (* gives the new [owned_by] value of an address under an abstract state with a
     pointer reassigned, assuming the pointer is in a VM's page table *)
  Lemma owned_by_abstract_reassign_pointer_stage2
        abst conc ptr attrs begin end_ (a : paddr_t) v ppool :
    (* v is in the vms list *)
    In v vms ->
    (* ptr is located under v's root ptable *)
    (exists idxs,
        has_location
          (ptable_deref conc) ppool ptr
          (table_loc ppool (vm_ptable v) idxs)) ->
    (* ptr is not located anywhere else *)
    locations_exclusive conc.(ptable_deref) ppool ->
    (* list of addresses that changed *)
    let changed_addrs :=
        addresses_under_pointer_in_range
          (ptable_deref conc) ptr (vm_ptable v) begin end_ Stage2 in
    (* new abstract state *)
    let new_abst := 
        abstract_reassign_pointer abst conc ptr attrs begin end_ in
    forall e : entity_id,
      In e (owned_by new_abst a) <->
      if (in_dec paddr_t_eq_dec a changed_addrs)
      then
        if valid_from_attrs attrs Stage2
        then e = inl (vm_id v) \/ In e (owned_by abst a)
        else e <> inl (vm_id v) /\ In e (owned_by abst a)
      else In e (owned_by abst a).
  Admitted. (* TODO *)

  (* gives the new [owned_by] value of an address under an abstract state with a
     pointer reassigned, assuming the pointer is in hafnium's table *)
  Lemma owned_by_abstract_reassign_pointer_stage1
        abst conc ptr attrs begin end_ (a : paddr_t) ppool :
    (* ptr is located under hafnium's root ptable *)
    (exists idxs,
        has_location (ptable_deref conc) ppool ptr
          (table_loc ppool hafnium_ptable idxs)) ->
    (* ptr is not located anywhere else *)
    locations_exclusive conc.(ptable_deref) ppool ->
    (* list of addresses that changed *)
    let changed_addrs :=
        addresses_under_pointer_in_range
          (ptable_deref conc) ptr hafnium_ptable begin end_ Stage1 in
    (* new abstract state *)
    let new_abst := 
        abstract_reassign_pointer abst conc ptr attrs begin end_ in
    forall e : entity_id,
      In e (owned_by new_abst a) <->
      if (in_dec paddr_t_eq_dec a changed_addrs)
      then
        if owned_from_attrs attrs Stage1
        then e = inr hid \/ In e (owned_by abst a)
        else e <> inr hid /\ In e (owned_by abst a)
      else In e (owned_by abst a).
  Admitted. (* TODO *)

  Lemma index_sequences_to_pointer_change_start deref ptr root_ptable stage t ppool :
    In root_ptable all_root_ptables ->
    locations_exclusive deref ppool ->
    index_sequences_to_pointer
      (fun ptr' : ptable_pointer => if ptable_pointer_eq_dec ptr ptr' then t else deref ptr')
      ptr root_ptable stage = index_sequences_to_pointer deref ptr root_ptable stage.
  Admitted.

  (* states that if we change the ptable_deref function but only affect pointers
     in the stage-1 table, then stage-2 lookups are unaltered *)
  Lemma page_lookup_proper_stage2 deref1 deref2 root_ptable ppool a:
    (* all pointers have at most 1 location *)
    locations_exclusive deref1 ppool ->
    (* root_ptable is a stage-2 table *)
    In root_ptable (map vm_ptable vms) ->
    (* forall pointers, if the pointer is NOT in the stage1 page table, then
       deref1 is the same as deref2 *) 
    (forall ptr,
        index_sequences_to_pointer deref1 ptr hafnium_ptable Stage1 = nil ->
        deref1 ptr = deref2 ptr) ->
      page_lookup deref1 root_ptable Stage2 a = page_lookup deref2 root_ptable Stage2 a.
  Admitted. (* TODO *)

  Definition vm_page_table_unchanged deref1 deref2 v : Prop :=
    forall ptr,
      index_sequences_to_pointer deref1 ptr (vm_ptable v) Stage2 <> nil
      \/ index_sequences_to_pointer deref2 ptr (vm_ptable v) Stage2 <> nil ->
      deref1 ptr = deref2 ptr.

  Definition hafnium_page_table_unchanged deref1 deref2 : Prop :=
    forall ptr,
      index_sequences_to_pointer deref1 ptr hafnium_ptable Stage1 <> nil
      \/ index_sequences_to_pointer deref2 ptr hafnium_ptable Stage1 <> nil ->
      deref1 ptr = deref2 ptr.

  Lemma vm_table_unchanged_sym deref1 deref2 v :
    vm_page_table_unchanged deref1 deref2 v ->
    vm_page_table_unchanged deref2 deref1 v.
  Proof.
    cbv [vm_page_table_unchanged]; basics;
      symmetry; solver.
  Qed.

  Lemma hafnium_table_unchanged_sym deref1 deref2 :
    hafnium_page_table_unchanged deref1 deref2 ->
    hafnium_page_table_unchanged deref2 deref1.
  Proof.
    cbv [hafnium_page_table_unchanged]; basics;
      symmetry; solver.
  Qed.

  (* Modifying the stage-1 table doesn't change the VM page tables *)
  Lemma vm_table_unchanged_stage1 deref ptr idxs t ppool :
    has_location deref ppool ptr (table_loc ppool hafnium_ptable idxs) ->
    locations_exclusive deref ppool ->
    forall v,
      vm_page_table_unchanged deref (update_deref deref ptr t) v.
  Admitted. (* TODO *)

  (* Modifying the stage-2 tables doesn't change hafnium's table *)
  Lemma hafnium_table_unchanged_stage2 deref ptr idxs t ppool root_ptable :
    In root_ptable (map vm_ptable vms) ->
    has_location deref ppool ptr (table_loc ppool root_ptable idxs) ->
    locations_exclusive deref ppool ->
    hafnium_page_table_unchanged deref (update_deref deref ptr t).
  Admitted. (* TODO *)

  (* If hafnium's table is unchanged, then haf_page_valid is the same for all
     addresses *)
  Lemma haf_page_valid_proper conc conc' a:
    hafnium_page_table_unchanged conc.(ptable_deref) conc'.(ptable_deref) -> 
    haf_page_valid conc a ->
    haf_page_valid conc' a.
  Admitted. (* TODO *)

  (* If hafnium's table is unchanged, then haf_page_owned is the same for all
     addresses *)
  Lemma haf_page_owned_proper conc conc' a:
    hafnium_page_table_unchanged conc.(ptable_deref) conc'.(ptable_deref) -> 
    haf_page_owned conc a ->
    haf_page_owned conc' a.
  Admitted. (* TODO *)

  (* If a VM's page tables are unchanged, then vm_page_valid is the same for all
     addresses *)
  Lemma vm_page_valid_proper conc conc' v a:
    vm_page_table_unchanged conc.(ptable_deref) conc'.(ptable_deref) v -> 
    vm_page_valid conc v a ->
    vm_page_valid conc' v a.
  Admitted. (* TODO *)

  (* If a VM's page tables are unchanged, then vm_page_owned is the same for all
     addresses *)
  Lemma vm_page_owned_proper conc conc' v a:
    vm_page_table_unchanged conc.(ptable_deref) conc'.(ptable_deref) v  -> 
    vm_page_owned conc v a ->
    vm_page_owned conc' v a.
  Admitted. (* TODO *)

  (* If an address isn't in the range that changed, then vm_page_valid remains true *)
  Lemma vm_page_valid_unaffected_address
        conc ptr ppool v a begin end_ attrs idxs level t :
    (* ptr exists in v's page table *)
    has_location
      (ptable_deref conc) ppool ptr (table_loc ppool (vm_ptable v) idxs) ->
    (* attributes of the new table match the old, except in the rang specified *)
    attrs_changed_in_range (ptable_deref conc) idxs (ptable_deref conc ptr) t
                           level attrs begin end_ Stage2 ->
    (* a is not one of the addresses that changed *)
    ~ In a (addresses_under_pointer_in_range
              conc.(ptable_deref) ptr (vm_ptable v) begin end_ Stage2) ->
    vm_page_valid conc v a ->
    vm_page_valid (reassign_pointer conc ptr t) v a.
  Admitted. (* TODO *)

  (* TODO : move *)
  Lemma vm_find_Some v : In v vms -> vm_find (vm_id v) = Some v.
  Admitted. (* TODO *)
  Hint Resolve vm_find_Some.

  (* TODO : move *)
  Definition vm_eq_dec (v1 v2 : vm) : {v1 = v2} + {v1 <> v2}.
  Proof.
    repeat match goal with
           | _ => progress subst
           | x : vm |- _ => destruct x
           | x : mm_ptable |- _ => destruct x
           | _ => right; congruence
           | _ => left; congruence
           | x : nat, y : nat |- _ => destruct (Nat.eq_dec x y)
           | x : paddr_t, y : paddr_t |- _ => destruct (paddr_t_eq_dec x y)
           end.
  Defined.

  Lemma reassign_pointer_represents_stage1 conc ptr t abst idxs :
    represents abst conc ->
    has_location (ptable_deref conc) (api_page_pool conc) ptr
                 (table_loc (api_page_pool conc) hafnium_ptable idxs) ->
    let conc' := conc.(reassign_pointer) ptr t in
    locations_exclusive conc.(ptable_deref) conc.(api_page_pool) ->
    locations_exclusive conc'.(ptable_deref) conc.(api_page_pool) ->
    forall attrs level begin end_,
      attrs_changed_in_range (ptable_deref conc) idxs (ptable_deref conc ptr) t
                             level attrs begin end_ Stage1 ->
      represents (abstract_reassign_pointer
                    abst conc ptr attrs begin end_)
                 conc'.
  Proof.
    cbv [reassign_pointer represents is_valid].
    cbv [has_location_in_state].
    cbn [ptable_deref api_page_pool].
    basics; try solver; [ | | | ].
    { (* stage-2 [accessible_by] states match *) 
      rewrite accessible_by_abstract_reassign_pointer_stage1 by eauto.
      repeat match goal with
             | _ => progress basics
             | |- _ <-> _ => split
             | |- inl _ = inr _ \/ _ => right
             | |- inr _ = inl _ \/ _ => right
             | H : (forall _ _, In (?f _) _ <-> exists _, _),
                   H' : In (?f _) _ |- exists _, _ =>
               apply H in H'; let x := fresh in destruct H' as [x H']; exists x
             | H : (forall _ _, In (?f _) _ <-> exists _, _) |- In (?f _) _ =>
               apply H
             | _ => eapply vm_page_valid_proper; [|eassumption]
             | _ => eapply vm_table_unchanged_stage1; solver
             | _ => eapply vm_table_unchanged_sym;
                      eapply vm_table_unchanged_stage1; solver
             | _ => break_match
             | |- exists _, _ /\ _ => eexists; split; try eassumption; [ ]
             | _ => solver
             end. }
    { (* stage-1 [accessible_by] states match *) 
      admit. }
    { (* stage-2 [owned_by] states match *) 
      rewrite owned_by_abstract_reassign_pointer_stage1 by eauto.
      repeat match goal with
             | _ => progress basics
             | |- _ <-> _ => split
             | |- inl _ = inr _ \/ _ => right
             | |- inr _ = inl _ \/ _ => right
             | H : (forall _ _, In (?f _) _ <-> exists _, _),
                   H' : In (?f _) _ |- exists _, _ =>
               apply H in H'; let x := fresh in destruct H' as [x H']; exists x
             | H : (forall _ _, In (?f _) _ <-> exists _, _) |- In (?f _) _ =>
               apply H
             | _ => eapply vm_page_owned_proper; [|eassumption]
             | _ => eapply vm_table_unchanged_stage1; solver
             | _ => eapply vm_table_unchanged_sym;
                      eapply vm_table_unchanged_stage1; solver
             | _ => break_match
             | |- exists _, _ /\ _ => eexists; split; try eassumption; [ ]
             | _ => solver
             end. }
    { (* stage-1 [owned_by] states match *) 
      admit. }
  Admitted.

  Lemma reassign_pointer_represents_stage2 conc ptr t abst idxs v :
    represents abst conc ->
    In v vms ->
    has_location (ptable_deref conc) (api_page_pool conc) ptr
                 (table_loc (api_page_pool conc) (vm_ptable v) idxs) ->
    let conc' := conc.(reassign_pointer) ptr t in
    locations_exclusive conc.(ptable_deref) conc.(api_page_pool) ->
    locations_exclusive conc'.(ptable_deref) conc.(api_page_pool) ->
    forall attrs level begin end_,
      attrs_changed_in_range (ptable_deref conc) idxs (ptable_deref conc ptr) t
                             level attrs begin end_ Stage2 ->
      represents (abstract_reassign_pointer
                    abst conc ptr attrs begin end_)
                 conc'.
  Proof.
    cbv [reassign_pointer represents is_valid].
    cbv [has_location_in_state].
    cbn [ptable_deref api_page_pool].
    basics; try solver; [ | | | ].
    { (* stage-2 [accessible_by] states match *) 
        rewrite accessible_by_abstract_reassign_pointer_stage2 by eauto.
        repeat match goal with
               | _ => progress basics
               | |- _ <-> _ => split
               | |- inl ?x = inl ?y \/ _ =>
                 destruct (Nat.eq_dec x y); [left; basics; solver | right]
               | H : (forall _ _, In (?f _) _ <-> exists _, _),
                     H' : In (?f _) _ |- exists _, _ =>
                 apply H in H'; let x := fresh in destruct H' as [x H']; exists x
               | H : (forall _ _, In (?f _) _ <-> exists _, _) |- In (?f _) _ =>
                 apply H
               | _ => break_match
               | H : _ |- exists v, vm_find (vm_id ?x) = Some v /\ _ =>
                 exists x; split; [ solver | ]
               | |- exists _, _ /\ _ => eexists; split; try eassumption; [ ]
               | _ => solver
               end.

        (* main reasoning cases:
           A : not in addresses_under_pointer -> nothing changed wrt a (need new version of page_valid_proper)
           B : changed pointer in a different VM's table -> page_valid_proper
           C : page valid for x under new deref -> new attrs say invalid -> in addresses_under_pointer ptr ->
                    ptr in x2's page table -> x <> x2
           D : valid before -> new attributes say valid -> valid now
         *)

        (* PROBLEM with A :
           
           it's addresses_under_pointer_in_range, not addresses_under_pointer -- we need to somehow have the
           information that a is unchanged unless it's in range
        *)


        
        (* order of attack : A, B, D, C *)

        { (* here, we know it's valid even though it was changed because attrs say valid *)
          (* D *)
          admit. }
        { (* here, need to split on whether H11 = x0. If so, same as last case. If not, then
             we need to use vm_page_valid_proper to say that the pointer can't be in H11's table *)
          (* destruct dec (H11 = x0); [ D | B ] *)
          admit. }
        { (* here, we know H12 <> x0 and same as second clause of last case *)
          (* B *)
          admit. }
        { (* here, a was not affected by the change because it's not in the addresses_under_pointer *)
          (* destruct dec (H10 = x0); [ A | B ] *)
          match goal with
          | x : vm, y : vm |- _ => destruct (vm_eq_dec x y); basics
          end.
          { eapply vm_page_valid_unaffected_address; eauto. }
          (* A *)
          admit. }
        { (* we know x <> x0, so ptr not in x's table and page_valid_proper, same as second clause of case 2 and as case 3 *) 
          (* B *)
          admit. }
        { (* we know the page is valid for x under the new deref and that the
             new attributes say it's invalid, so for x0 it would be invalid;
             therefore x <> x0 *)
          (* C *)
          admit. }
        { (* we know the page is valid for x under the new deref and that the
             new attributes say it's invalid, so for x0 it would be invalid;
             therefore x <> x0 and x's page table hasn't changed -- solve with
             page_valid_proper *)
          (* C; B *)
          admit. }
        { (* a unaffected because it's not in the addresses_under_pointer *)
          (* A *)
          admit. } }
    { (* stage-1 [accessible_by] states match *)
      admit. }
    { (* stage-2 [owned_by] states match *)
      admit. }
    { (* stage-1 [owned_by] states match *)
      admit. }
  Admitted.

  Lemma reassign_pointer_represents conc ptr t abst idxs root_ptable stage :
    represents abst conc ->
    has_location (ptable_deref conc) (api_page_pool conc) ptr
                 (table_loc (api_page_pool conc) root_ptable idxs) ->
    root_ptable_matches_stage root_ptable stage ->
    let conc' := conc.(reassign_pointer) ptr t in
    locations_exclusive conc.(ptable_deref) conc.(api_page_pool) ->
    locations_exclusive conc'.(ptable_deref) conc.(api_page_pool) ->
    forall attrs level begin end_,
      attrs_changed_in_range (ptable_deref conc) idxs (ptable_deref conc ptr) t
                             level attrs begin end_ stage ->
      represents (abstract_reassign_pointer
                    abst conc ptr attrs begin end_)
                 conc'.
  Proof.
    cbv [has_location_in_state root_ptable_matches_stage].
    intros.
    assert (~ In hafnium_ptable (map vm_ptable vms))
      by (pose proof no_duplicate_ptables; cbv [all_root_ptables] in *;
          invert_list_properties; solver).
    match goal with
    | H : context [has_location _] |- _ => pose proof H; invert H
    end; (destruct stage; try solver; [ ]).
    { eapply reassign_pointer_represents_stage1; eauto. }
    { match goal with
      | H : _ |- _ => apply in_map_iff in H; basics
      end.
      eapply reassign_pointer_represents_stage2; eauto. }
  Qed.

  (* if the address range is empty (end_ <= begin), then there can be no
     addresses in that range under the given pointer *)
  Lemma addresses_under_pointer_in_range_empty
        deref ptr root_ptbl begin end_ stage :
    (end_ <= begin)%N ->
    addresses_under_pointer_in_range deref ptr root_ptbl begin end_ stage = nil.
  Proof.
    intros; cbv [addresses_under_pointer_in_range].
    replace (end_ - begin)%N with 0%N by solver.
    reflexivity.
  Qed.

  (* if the address range is empty (end_ <= begin), then the abstract state
     doesn't change *)
  Lemma abstract_reassign_pointer_for_entity_trivial
        abst conc ptr owned valid e root_ptable begin end_ :
    (end_ <= begin)%N ->
    abstract_state_equiv
      abst
      (abstract_reassign_pointer_for_entity
         abst conc ptr owned valid e root_ptable begin end_).
  Proof.
    intros; cbv [abstract_reassign_pointer_for_entity].
    rewrite addresses_under_pointer_in_range_empty by solver.
    cbn [fold_right]; auto.
  Qed.

  (* if the address range is empty (end_ <= begin), then the abstract state
     doesn't change *)
  Lemma abstract_reassign_pointer_trivial abst conc ptr attrs begin end_:
    (end_ <= begin)%N ->
    abstract_state_equiv
      abst
      (abstract_reassign_pointer abst conc ptr attrs begin end_).
  Proof.
    intros; cbv [abstract_reassign_pointer].
    apply fold_right_invariant; intros;
      [ eapply abstract_state_equiv_trans; [eassumption|] | ];
      auto using abstract_reassign_pointer_for_entity_trivial.
  Qed.

  Lemma abstract_reassign_pointer_for_entity_change_concrete
        abst conc conc' ptr owned valid e root_ptr begin end_ :
    index_sequences_to_pointer conc.(ptable_deref) ptr root_ptr
    = index_sequences_to_pointer conc'.(ptable_deref) ptr root_ptr ->
    abstract_reassign_pointer_for_entity
      abst conc ptr owned valid e root_ptr begin end_
    = abstract_reassign_pointer_for_entity
        abst conc' ptr owned valid e root_ptr begin end_.
  Proof.
    cbv beta iota delta [abstract_reassign_pointer_for_entity
                           addresses_under_pointer_in_range].
    intro Heq. rewrite Heq. reflexivity.
  Qed.

  Lemma abstract_reassign_pointer_change_concrete
        abst conc conc' ptr attrs begin_index end_index :
    Forall (fun root =>
              index_sequences_to_pointer conc.(ptable_deref) ptr root
              = index_sequences_to_pointer conc'.(ptable_deref) ptr root)
           all_root_ptables ->
    abstract_reassign_pointer abst conc ptr attrs begin_index end_index
    = abstract_reassign_pointer abst conc' ptr attrs begin_index end_index.
  Proof.
    cbv [abstract_reassign_pointer all_root_ptables].
    repeat match goal with
           | _ => progress basics
           | _ => progress invert_list_properties
           | H : _ |- _ => apply Forall_map in H; rewrite Forall_forall in H
           | _ =>
             rewrite abstract_reassign_pointer_for_entity_change_concrete
               with (conc':=conc') by eauto
           | _ => apply fold_right_ext
           | _ => solve
                    [auto using
                          abstract_reassign_pointer_for_entity_change_concrete]
           end.
  Qed.

  (* attrs_changed_in_range doesn't care if we reassign the pointer we started from *)
  (* TODO : fill in preconditions *)
  Lemma attrs_changed_in_range_reassign_pointer
        c ptr new_table t level attrs begin end_ idxs stage :
    (* this precondition is so we know c doesn't show up in the new table *)
    is_valid (reassign_pointer c ptr new_table) ->
    has_location_in_state c ptr idxs ->
    attrs_changed_in_range
      (ptable_deref c) idxs (ptable_deref c ptr) t level attrs begin end_ stage ->
    attrs_changed_in_range
      (ptable_deref (reassign_pointer c ptr new_table))
      idxs (ptable_deref c ptr) t level attrs begin end_ stage.
  Admitted. (* TODO *)

  Definition no_addresses_in_range deref ptr begin end_ : Prop :=
    Forall
      (fun root_ptable =>
         addresses_under_pointer_in_range deref ptr root_ptable begin end_ Stage2 = nil)
      (map vm_ptable vms)
    /\ addresses_under_pointer_in_range deref ptr hafnium_ptable begin end_ Stage1 = nil.

  (* abstract_reassign_pointer is a no-op if the given tables don't have any
     addresses in range *)
  (* TODO: fill in preconditions; likely needs to know that the table is at the
     right level *)
  Lemma abstract_reassign_pointer_low
        abst conc attrs begin end_ t_ptrs :
    Forall
      (fun ptr => no_addresses_in_range conc.(ptable_deref) ptr begin end_)
      t_ptrs ->
    abstract_state_equiv
      abst
      (fold_left
         (fun abst t_ptr =>
            abstract_reassign_pointer abst conc t_ptr attrs begin end_)
         t_ptrs
         abst).
  Admitted.

  (* we can expand the range to include pointers that are out of range *)
  (* TODO: fill in preconditions; likely needs to know that the table is at the
     right level *)
  Lemma abstract_reassign_pointer_high
        abst conc attrs begin end_ i t_ptrs :
    Forall
      (fun ptr => no_addresses_in_range conc.(ptable_deref) ptr begin end_)
      (skipn i t_ptrs) ->
    abstract_state_equiv
      (fold_left
         (fun abst t_ptr =>
            abstract_reassign_pointer abst conc t_ptr attrs begin end_)
         (firstn i t_ptrs)
         abst)
      (fold_left
         (fun abst t_ptr =>
            abstract_reassign_pointer abst conc t_ptr attrs begin end_)
         t_ptrs
         abst).
  Admitted.
End Proofs.