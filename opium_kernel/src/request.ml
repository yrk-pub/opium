type t =
  { version : Version.t
  ; target : string
  ; headers : Headers.t
  ; meth : Method.t
  ; body : Body.t
  ; env : Hmap0.t
  }

let make
    ?(version = { Version.major = 1; minor = 1 })
    ?(body = Body.empty)
    ?(env = Hmap0.empty)
    ?(headers = Headers.empty)
    target
    meth
  =
  { version; target; headers; meth; body; env }
;;

let get ?version ?body ?env ?headers target =
  make ?version ?body ?env ?headers target `GET
;;

let post ?version ?body ?env ?headers target =
  make ?version ?body ?env ?headers target `POST
;;

let put ?version ?body ?env ?headers target =
  make ?version ?body ?env ?headers target `PUT
;;

let delete ?version ?body ?env ?headers target =
  make ?version ?body ?env ?headers target `DELETE
;;

let of_string'
    ?(content_type = "text/plain")
    ?version
    ?env
    ?(headers = Headers.empty)
    target
    meth
    body
  =
  let headers = Headers.add_unless_exists headers "Content-Type" content_type in
  make ?version ~headers ~body:(Body.of_string body) ?env target meth
;;

let of_plain_text ?version ?headers ?env ~body target meth =
  of_string' ?version ?env ?headers target meth body
;;

let of_json ?version ?headers ?env ~body target meth =
  of_string'
    ~content_type:"application/json"
    ?version
    ?headers
    ?env
    target
    meth
    (body |> Yojson.Safe.to_string)
;;

let of_urlencoded ?version ?headers ?env ~body target meth =
  of_string'
    ~content_type:"application/x-www-form-urlencoded"
    ?version
    ?headers
    ?env
    target
    meth
    (body |> Uri.encoded_of_query)
;;

let to_json_exn t =
  let open Lwt.Syntax in
  let* body = t.body |> Body.copy |> Body.to_string in
  Lwt.return @@ Yojson.Safe.from_string body
;;

let to_json t =
  let open Lwt.Syntax in
  Lwt.catch
    (fun () ->
      let+ json = to_json_exn t in
      Some json)
    (function
      | _ -> Lwt.return None)
;;

let to_plain_text t = Body.copy t.body |> Body.to_string

let to_urlencoded t =
  let open Lwt.Syntax in
  let* body = t.body |> Body.copy |> Body.to_string in
  body |> Uri.query_of_encoded |> Lwt.return
;;

let header header t = Headers.get t.headers header
let headers header t = Headers.get_multi t.headers header
let add_header (k, v) t = { t with headers = Headers.add t.headers k v }

let add_header_or_replace (k, v) t =
  { t with
    headers =
      (if Headers.mem t.headers k
      then Headers.replace t.headers k v
      else Headers.add t.headers k v)
  }
;;

let add_header_unless_exists (k, v) t =
  { t with headers = Headers.add_unless_exists t.headers k v }
;;

let add_headers hs t = { t with headers = Headers.add_list t.headers hs }

let add_headers_or_replace hs t =
  ListLabels.fold_left hs ~init:t ~f:(fun acc el -> add_header_or_replace el acc)
;;

let add_headers_unless_exists hs t =
  { t with headers = Headers.add_list_unless_exists t.headers hs }
;;

let remove_header key t = { t with headers = Headers.remove t.headers key }

let cookie ?signed_with cookie t =
  Cookie.cookie_of_headers ?signed_with cookie (t.headers |> Headers.to_list)
  |> Option.map snd
;;

let cookies ?signed_with t =
  Cookie.cookies_of_headers ?signed_with (t.headers |> Headers.to_list)
;;

let replace_or_add_to_list ~f to_add l =
  let found = ref false in
  let rec aux acc l =
    match l with
    | [] -> if not !found then to_add :: acc |> List.rev else List.rev acc
    | el :: rest ->
      if f el to_add
      then (
        found := true;
        aux (to_add :: acc) rest)
      else aux (el :: acc) rest
  in
  aux [] l
;;

let add_cookie ?sign_with (k, v) t =
  let cookies = cookies t in
  let cookies =
    replace_or_add_to_list
      ~f:(fun (k2, _v2) _ -> String.equal k k2)
      ( k
      , match sign_with with
        | Some signer -> Cookie.Signer.sign signer v
        | None -> v )
      cookies
  in
  let cookie_header =
    cookies |> ListLabels.map ~f:Cookie.make |> Cookie.to_cookie_header
  in
  add_header_or_replace cookie_header t
;;

let add_cookie_unless_exists ?sign_with (k, v) t =
  let cookies = cookies t in
  if ListLabels.exists cookies ~f:(fun (k2, _v2) -> String.equal k2 k)
  then t
  else add_cookie ?sign_with (k, v) t
;;

let remove_cookie key t =
  let cookie_header =
    cookies t
    |> ListLabels.filter ~f:(fun (k, _) -> not (String.equal k key))
    |> List.map Cookie.make
    |> Cookie.to_cookie_header
  in
  add_header_or_replace cookie_header t
;;

let content_type t = header "Content-Type" t
let set_content_type s t = add_header ("Content-Type", s) t

let to_multipart_form_data
    ?(callback = fun ~name:_ ~filename:_ _line -> Lwt.return_unit)
    t
  =
  match t.meth, content_type t with
  | `POST, Some content_type
    when String.length content_type > 30
         && String.sub content_type 0 30 = "multipart/form-data; boundary=" ->
    let open Lwt.Syntax in
    let body = t.body |> Body.copy |> Body.to_stream in
    let* result = Multipart_form_data.parse ~stream:body ~content_type ~callback in
    Lwt.return @@ Some result
  | _ -> Lwt.return None
;;

let to_multipart_form_data_exn ?callback t =
  let open Lwt.Syntax in
  let* result = to_multipart_form_data ?callback t in
  match result with
  | Some r -> Lwt.return r
  | None ->
    raise (Invalid_argument "The request is not a valid multipart/form-data request.")
;;

let find_in_query key query =
  query
  |> ListLabels.find_opt ~f:(fun (k, _) -> k = key)
  |> Option.map (fun (_, r) -> r)
  |> fun opt ->
  Option.bind opt (fun x ->
      try Some (List.hd x) with
      | Not_found -> None)
;;

let urlencoded key t =
  let open Lwt.Syntax in
  let* query = to_urlencoded t in
  Lwt.return @@ find_in_query key query
;;

let urlencoded_exn key t =
  let open Lwt.Syntax in
  let+ o = urlencoded key t in
  Option.get o
;;

let query_list t = t.target |> Uri.of_string |> Uri.query
let query key t = query_list t |> find_in_query key
let query_exn key t = query key t |> Option.get

let sexp_of_t { version; target; headers; meth; body; env } =
  let open Sexplib0.Sexp_conv in
  let open Sexplib0.Sexp in
  List
    [ List [ Atom "version"; Version.sexp_of_t version ]
    ; List [ Atom "target"; sexp_of_string target ]
    ; List [ Atom "method"; Method.sexp_of_t meth ]
    ; List [ Atom "headers"; Headers.sexp_of_t headers ]
    ; List [ Atom "body"; Body.sexp_of_t body ]
    ; List [ Atom "env"; Hmap0.sexp_of_t env ]
    ]
;;

let pp fmt t = Sexplib0.Sexp.pp_hum fmt (sexp_of_t t)

let pp_hum fmt t =
  Format.fprintf
    fmt
    "%s %s %s\n%s\n\n%a\n%!"
    (Method.to_string t.meth)
    t.target
    (Version.to_string t.version)
    (Headers.to_string t.headers)
    Body.pp_hum
    t.body
;;
