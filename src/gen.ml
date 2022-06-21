open Core
open Consts
open Lang

(***** Term generation metrics {{{ *****)

type metric =
  { size : int
  ; lambdas : int
  }

let rec gen_metric (size:int) (lambdas:int) : metric = { size = size; lambdas = lambdas }

(***** }}} *****)

(***** Memoization Tables {{{ *****)

module GTS : sig
  type t = { g : Ctx.t; t : typ; met : metric }
  val make_key : Ctx.t -> typ -> metric -> t
  include Hashable.S with type t := t
end = struct
  module T = struct
    type t = { g : Ctx.t; t : typ; met : metric }
    let make_key (g:Ctx.t) (t:typ) (met:metric) = { g = g; t = t; met = met }
    let hash k =
      let rec hash_ctx =
        List.fold_left
          ~f:(fun ans ((x, (t, _)), n) -> (String.hash x) lxor (hash_typ t) lxor (Int.hash n) lxor ans)
          ~init:102397
      and hash_typ t =
        match t with
        | TBase x -> String.hash x
        | TArr (t1, t2) -> abs ((hash_typ t1) + 79 * (hash_typ t2) + 73)
      and hash_met met =
        Int.hash met.size lxor Int.hash met.lambdas lxor 7919
      in
        (hash_ctx (List.zip_exn k.g (Util.range1 (Ctx.size k.g)))) lxor (hash_typ k.t) lxor (hash_met k.met)
    let hash_fold_t _ = failwith "GTS.hash_fold_t unimplemented"
    let compare = compare   (* NOTE: use the built-in compare function *)
    let sexp_of_t (_:t) : Sexp.t = failwith "GTS.sexp_of_t unimplemented"
    let t_of_sexp (_:Sexp.t) : t = failwith "GTS.t_of_sexp unimplemented"
  end
  include T
  include Hashable.Make(T)
end

let memo_eexp_tbl     : (GTS.t, exp Cord.t) Hashtbl.t =
  Hashtbl.create (module GTS.Hash_queue.Key)
let memo_eexp_rel_tbl : (GTS.t, exp Cord.t) Hashtbl.t =
  Hashtbl.create (module GTS.Hash_queue.Key)
let memo_iexp_tbl     : (GTS.t, exp Cord.t) Hashtbl.t =
  Hashtbl.create (module GTS.Hash_queue.Key)
let memo_iexp_rel_tbl : (GTS.t, exp Cord.t) Hashtbl.t =
  Hashtbl.create (module GTS.Hash_queue.Key)

(***** }}} *****)

(***** Term Generation and Synthesis {{{ *****)

let find_in_table tbl key =
  if !eterm_lookup_tables then
    Hashtbl.find tbl key
  else
    None

let rec gen_eexp (tmo:Timeout.t) (s:Sig.t) (g:Ctx.t) (t:typ) (met:metric) : exp Cord.t =
  Timeout.check_timeout tmo;
  if met.size <= 0 then Cord.empty else
  let key = GTS.make_key g t met in
  match find_in_table memo_eexp_tbl key with
  | Some ans -> begin
    end; ans
  | None ->
    let ans = begin match Ctx.peel g with
    | None -> Cord.empty
    | Some ((xrel, (trel, bs)), g) ->
      let weakened = gen_eexp tmo s g t met in
      let relevant = gen_eexp_rel tmo s (xrel, trel, bs) g t met in
      Cord.concat weakened relevant
    end in
      (Hashtbl.set memo_eexp_tbl key ans; ans)

and gen_eexp_rel (tmo:Timeout.t) (s:Sig.t)
                 ((xrel, trel, bs):id * typ * Ctx.bindspec list)
                 (g:Ctx.t) (t:typ) (met:metric) : exp Cord.t =
  Timeout.check_timeout tmo;
  if met.size <= 0 then Cord.empty else
  let key = GTS.make_key (Ctx.insert xrel trel g) t met in
  match find_in_table memo_eexp_rel_tbl key with
  | Some ans -> ans
  | None ->
    let ans = if met.size = 1 && trel = t then
        Cord.cons (EVar xrel) Cord.empty
      else
        gen_eexp_rel_app tmo s (xrel, trel, bs) g t met
    in
    Hashtbl.set memo_eexp_rel_tbl key ans; ans

and gen_eexp_rel_app (tmo:Timeout.t) (s:Sig.t)
                     ((xrel, trel, bs):id * typ * Ctx.bindspec list)
                     (g:Ctx.t) (t:typ) (met:metric) : exp Cord.t =
  Timeout.check_timeout tmo;
  if met.size < 2 then Cord.empty else
  let rec extract_producer t u =
    match u with
    | TArr (t1, t2) -> if t2 = t then Some u else extract_producer t t2
    | TBase d -> None
  in
  let gen_apps ts met
      (e1s_fn:Sig.t -> Ctx.t -> (id * typ * Ctx.bindspec list) -> typ -> metric -> exp Cord.t)
      (e2s_fn:Sig.t -> Ctx.t -> (id * typ * Ctx.bindspec list) -> typ -> metric -> exp Cord.t) =
    ts |> Cord.of_list |> Cord.concat_map ~f:(fun t ->
      begin match t with
      | TArr (t1, _) ->
          Util.partitions (met.size - 1) 2 |> Cord.of_list
            |> Cord.concat_map ~f:(fun part ->
              begin match part with
              | [n1; n2] ->
                  let e1s = e1s_fn s g (xrel, trel, bs) t { met with size = n1 } in
                  let e2s = e2s_fn s g (xrel, trel, bs) t1 { met with size = n2 } in
                  (* NOTE: re-insert the relevant variable into the context for analysis *)
                  let g = Ctx.insert_bindspec xrel trel bs g in
                  let (e1s_rec, e1s) = Util.separate ~f:(is_recursive_fun g) (Cord.to_list e1s) in
                  let es_rec =
                    Cord.concat_map ~f:(fun e1 ->
                    match check_recursive_fun g e1 with
                    | Some f ->
                        if n1 = 1 && n2 = 1 then
                          Cord.filter ~f:begin fun e ->
                            match e with
                            | EVar x -> Ctx.is_dec_arg x f g
                            | _ -> false
                          end e2s
                            |> Cord.map ~f:(fun x -> EApp (EVar f, x))
                        else
                          Cord.empty
                    | None -> failwith "(gen_eexp_rel_app) non-recursive function found"
                    ) (Cord.of_list e1s_rec)
                  in
                  let es_nonrec = Cord.cartesian_product [Cord.of_list e1s; e2s]
                    |> Cord.map ~f:(fun pair ->
                        begin match pair with
                        | [e1; e2] -> EApp (e1, e2)
                        | _ -> failwith "(gen_eexp_rel_app) invalid part found"
                        end)
                  in
                    Cord.concat es_nonrec es_rec
              | _ -> failwith "(gen_eexp_rel_app) invalid part found"
              end)
      | _ -> failwith "(get_eexp_rel_app) non-arrow type found"
      end)
  in
  let producer_types =
    Ctx.gather_types (Ctx.insert_bindspec xrel trel bs g)
      |> List.dedup_and_sort ~compare:compare
      |> List.fold_left ~f:(fun acc u ->
        begin match extract_producer t u with
        | Some prod -> prod :: acc
        | None -> acc
        end) ~init:[]
      |> List.dedup_and_sort ~compare:compare
  in

  (* To synthesize applications, there are two cases:
   * (1) xrel appears at the head of the application, i.e., must be a function
   *     that produces ts *)
  let head_relevant = gen_apps producer_types met
    (fun s g (xrel, trel, bs) t m -> gen_eexp_rel tmo s (xrel, trel, bs) g t m)
    (fun s g (xrel, trel, bs) t m -> gen_iexp tmo s (Ctx.insert_bindspec xrel trel bs g) t m)
  in
  (* (2) xrel does not appear at the head so it appears in the argument *)
  let head_not_relevant = gen_apps producer_types met
    (fun s g (xrel, trel, bs) t m -> gen_eexp tmo s g t m)
    (fun s g (xrel, trel, bs) t m -> gen_iexp_rel tmo s (xrel, trel, bs) g t m)
  in
  Cord.concat head_relevant head_not_relevant

and gen_iexp (tmo:Timeout.t) (s:Sig.t) (g:Ctx.t) (t:typ) (met:metric) : exp Cord.t =
  Timeout.check_timeout(tmo);
  if met.size <= 0 then Cord.empty else
  let key = GTS.make_key g t met in
  match find_in_table memo_iexp_tbl key with
  | Some ans -> ans
  | None ->
    let ans = begin match Ctx.peel g with
    | None ->
        let gen_ctor_one s g (c, (ts, _)) met =
          let argc = List.length ts in
          if argc = 0 && met.size = 1 then
            Cord.cons (ECtor (c, [])) Cord.empty
          else
            Util.partitions (met.size - 1) argc
              |> List.map ~f:(fun part -> List.zip_exn ts part) |> Cord.of_list
              |> Cord.concat_map ~f:(fun part -> begin
                   List.map ~f:(fun (t, n) -> gen_iexp tmo s g t { met with size = n }) part
                     |> Cord.cartesian_product
                     |> Cord.map ~f:(fun es -> ECtor (c, es))
                 end)
        in
        let gen_ctors s g dt =
          Sig.gather_ctors dt s |> Cord.of_list
            |> Cord.concat_map ~f:(fun ctor -> gen_ctor_one s g ctor met)
        in
        let gen_abs s g t1 t2 =
          let x = gen_var_base t1 |> fresh_id_from_ctx g in
          gen_iexp tmo s (Ctx.insert x t1 g) t2 { size = met.size; lambdas = met.lambdas - 1 }
            |> Cord.map ~f:(fun e -> EFun ((x, t1), e))
        in
        begin match t with
        | TBase dt -> gen_ctors s g dt
        | TArr (t1, t2) -> gen_abs s g t1 t2
        end
    | Some ((xrel, (trel, bs)), g) ->
      let weakened = gen_iexp tmo s g t met in
      let relevant = gen_iexp_rel tmo s (xrel, trel, bs) g t met in
      Cord.concat weakened relevant
    end in
    Hashtbl.set memo_iexp_tbl key ans; ans

and gen_iexp_rel (tmo:Timeout.t) (s:Sig.t)
                 ((xrel, trel, bs):id * typ * Ctx.bindspec list)
                 (g:Ctx.t) (t:typ) (met:metric) : exp Cord.t =
  Timeout.check_timeout tmo;
  if met.size <= 0 then Cord.empty else
  let key = GTS.make_key (Ctx.insert xrel trel g) t met in
  match Hashtbl.find memo_iexp_rel_tbl key with
  | Some ans -> ans
  | None ->
    let gen_ctor_one s g (c, (ts, _)) met =
      let argc = List.length ts in
      if argc = 0 && met.size = 1 then
        Cord.empty    (* NOTE: no nullary constructors can have relevant vars *)
      else
        let choices = Util.partitions_rel argc in
        let parts   = Util.partitions (met.size - 1) argc |> List.map ~f:(List.zip_exn ts) in
        List.cartesian_product parts choices
          |> List.map ~f:(fun (ps, cs) -> List.zip_exn ps cs) |> Cord.of_list
          |> Cord.concat_map ~f:(fun part -> begin
               List.map ~f:(fun ((t, n), ch) ->
                 let met = { met with size = n } in
                 begin match ch with
                 | Util.MayNot -> gen_iexp tmo s g t met
                 | Util.Must   -> gen_iexp_rel tmo s (xrel, trel, bs) g t met
                 | Util.May    -> gen_iexp tmo s (Ctx.insert_bindspec xrel trel bs g) t met
                 end) part
                 |> Cord.cartesian_product
                 |> Cord.map ~f:(fun es -> ECtor (c, es))
             end)
    in
    let gen_ctors s g dt =
      Sig.gather_ctors dt s |> Cord.of_list
        |> Cord.concat_map ~f:(fun ctor -> gen_ctor_one s g ctor met)
    in
    let gen_abs s g t1 t2 =
      let x = gen_var_base t1 |> fresh_id_from_ctx g in
      gen_iexp_rel tmo s (xrel, trel, bs) (Ctx.insert x t1 g) t2 { size = met.size; lambdas = met.lambdas - 1 }
        |> Cord.map ~f:(fun e -> EFun ((x, t1), e))
    in
    let ans =
      begin match t with
      | TBase dt -> gen_ctors s g dt
      | TArr (t1, t2) -> gen_abs s g t1 t2
      end
      |> Cord.concat (gen_eexp_rel tmo s (xrel, trel, bs) g t met)
    in
    Hashtbl.set memo_iexp_rel_tbl key ans; ans

(***** }}} *****)
