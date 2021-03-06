(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Lwt
open Xs_protocol
module Client = Xs_client.Client(Xs_transport_lwt_unix_client)
open Client

let ( |> ) a b = b a

(* So we can run against a real xenstore, place all nodes in a subtree *)
let prefix = "/bench"

let getdomainpath domid client =
	lwt dom_path = with_xs client (fun xs -> getdomainpath xs domid) in
	return (prefix ^ dom_path)

let readdir d client =
	try_lwt
		with_xs client (fun xs -> directory xs d)
	with Xs_protocol.Enoent _ ->
		return []

let read_opt path xs =
	try_lwt
		lwt x = read xs path in return (Some x)
	with Xs_protocol.Enoent _ ->
		return None

let exists path xs = read_opt path xs >|= (fun x -> x <> None)

module Device = struct

type kind = Vif | Vbd | Tap | Pci | Vfs | Vfb | Vkbd

let kind_of_string = function
  | "vif" -> Some Vif | "vbd" -> Some Vbd | "tap" -> Some Tap 
  | "pci" -> Some Pci | "vfs" -> Some Vfs | "vfb" -> Some Vfb 
  | "vkbd" -> Some Vkbd
  | x -> None

let string_of_kind = function
  | Vif -> "vif" | Vbd -> "vbd" | Tap -> "tap" | Pci -> "pci" | Vfs -> "vfs" | Vfb -> "vfb" | Vkbd -> "vkbd"

type devid = int
(** Represents one end of a device *)
type endpoint = { domid: int; kind: kind; devid: int }

(** Represent a device as a pair of endpoints *)
type device = { 
  frontend: endpoint;
  backend: endpoint
}

let parse_int i = 
	try
		Some (int_of_string i)
	with _ -> None

let rec split ?limit:(limit=(-1)) c s =
	let i = try String.index s c with Not_found -> -1 in
	let nlimit = if limit = -1 || limit = 0 then limit else limit - 1 in
	if i = -1 || nlimit = 0 then
		[ s ]
	else
		let a = String.sub s 0 i
		and b = String.sub s (i + 1) (String.length s - i - 1) in
		a :: (split ~limit: nlimit c b)

let parse_backend_link x = 
	match split '/' x with
		| [ ""; "local"; "domain"; domid; "backend"; kind; _; devid ] ->
			begin
				match parse_int domid, kind_of_string kind, parse_int devid with
					| Some domid, Some kind, Some devid ->
						Some { domid = domid; kind = kind; devid = devid }
					| _, _, _ -> None
			end
		| _ -> None

let to_list xs = List.fold_left (fun acc x -> match x with
	| Some x -> x :: acc
	| None -> acc
) [] xs

let list_kinds dir client =
	readdir dir client >|= List.map kind_of_string >|= to_list

(* NB: we only read data from the frontend directory. Therefore this gives
   the "frontend's point of view". *)
let list_frontends domid client =
	lwt dom_path = getdomainpath domid client in 
	let frontend_dir = dom_path ^ "/device" in
	lwt kinds = list_kinds frontend_dir client in

	lwt ll = Lwt_list.map_s
		(fun k ->
			let dir = Printf.sprintf "%s/%s" frontend_dir (string_of_kind k) in
			lwt devids = readdir dir client >|= List.map parse_int >|= to_list in
			Lwt_list.map_s
				(fun devid ->
					(* domain [domid] believes it has a frontend for
					   device [devid] *)
					let frontend = { domid = domid; kind = k; devid = devid } in
					try_lwt
						with_xs client
							(fun xs ->
								lwt x = read xs (Printf.sprintf "%s/%d/backend" dir devid) in
								match parse_backend_link x with
									| Some b -> return (Some { backend = b; frontend = frontend })
									| None -> return None
							)
					with _ -> return None
				) devids >|= to_list
		) kinds in
	return (List.concat ll)

(** Location of the backend in xenstore *)
let backend_path_of_device (x: device) client =
	lwt dom_path = getdomainpath x.backend.domid client in
	return (Printf.sprintf "%s/backend/%s/%u/%d" 
		dom_path
		(string_of_kind x.backend.kind)
		x.frontend.domid x.backend.devid)

(** Location of the backend error path *)
let backend_error_path_of_device (x: device) client =
	lwt dom_path = getdomainpath x.backend.domid client in
	return (Printf.sprintf "%s/error/backend/%s/%d"
		dom_path
		(string_of_kind x.backend.kind)
		x.frontend.domid)

(** Location of the frontend in xenstore *)
let frontend_path_of_device (x: device) client =
	lwt dom_path = getdomainpath x.backend.domid client in
	return (Printf.sprintf "%s/device/%s/%d"
		dom_path
		(string_of_kind x.frontend.kind)
		x.frontend.devid)

(** Location of the frontend error node *)
let frontend_error_path_of_device (x: device) client =
	lwt dom_path = getdomainpath x.frontend.domid client in
	return (Printf.sprintf "%s/error/device/%s/%d/error"
		dom_path
		(string_of_kind x.frontend.kind)
		x.frontend.devid)

let hard_shutdown_request (x: device) client =
	lwt backend_path = backend_path_of_device x client in
	lwt frontend_path = frontend_path_of_device x client in
	let online_path = backend_path ^ "/online" in
	with_xs client
		(fun xs ->
			lwt () = write xs online_path "0" in
			lwt () = rm xs frontend_path in
			return ()
		)

(* We store some transient data elsewhere in xenstore to avoid it getting
   deleted by accident when a domain shuts down. We should always zap this
   tree on boot. *)
let private_path = prefix ^ "/xapi"

(* The private data path is only used by xapi and ignored by frontend and backend *)
let get_private_path domid = Printf.sprintf "%s/%d" private_path domid

let get_private_data_path_of_device (x: device) = 
	Printf.sprintf "%s/private/%s/%d" (get_private_path x.frontend.domid) (string_of_kind x.backend.kind) x.backend.devid

(* Path in xenstore where we stuff our transient hotplug-related stuff *)
let get_hotplug_path (x: device) =
	Printf.sprintf "%s/hotplug/%s/%d" (get_private_path x.frontend.domid) (string_of_kind x.backend.kind) x.backend.devid

let get_private_data_path_of_device (x: device) = 
	Printf.sprintf "%s/private/%s/%d" (get_private_path x.frontend.domid) (string_of_kind x.backend.kind) x.backend.devid

let rm_device_state (x: device) client =
	with_xs client
		(fun xs ->
			lwt fe = frontend_path_of_device x client in
			lwt be = backend_path_of_device x client in
			lwt ber = backend_error_path_of_device x client in
			lwt fer = frontend_error_path_of_device x client in
			Lwt_list.iter_s (rm xs) [ fe; be; ber; Filename.dirname fer ]
		)

let hard_shutdown device client =
	lwt () = hard_shutdown_request device client in
	lwt () = rm_device_state device client in
	return ()

let add device client =
	let backend_list = []
	and frontend_list = []
	and private_list = [] in

	lwt frontend_path = frontend_path_of_device device client in
	lwt backend_path = backend_path_of_device device client in
	let hotplug_path = get_hotplug_path device in
	let private_data_path = get_private_data_path_of_device device in
	lwt () = with_xst client
		(fun xs ->
			lwt _ = exists (Printf.sprintf "/local/domain/%d/vm" device.backend.domid) xs in
			lwt _ = exists frontend_path xs in
			lwt () = try_lwt lwt () = rm xs frontend_path in return () with _ -> return () in
			lwt () = try_lwt lwt () = rm xs backend_path in return () with _ -> return () in

			(* CA-16259: don't clear the 'hotplug_path' because this is where we
			   record our own use of /dev/loop devices. Clearing this causes us to leak
			   one per PV .iso *)
			lwt () = mkdir xs frontend_path in
			lwt () = setperms xs frontend_path (Xs_protocol.ACL.({owner = device.frontend.domid; other = NONE; acl = [ device.backend.domid, READ ]})) in
			lwt () = mkdir xs backend_path in
			lwt () = setperms xs backend_path (Xs_protocol.ACL.({owner = device.backend.domid; other = NONE; acl = [ device.frontend.domid, READ ]})) in
			lwt () = mkdir xs hotplug_path in
			lwt () = setperms xs hotplug_path (Xs_protocol.ACL.({owner = device.backend.domid; other = NONE; acl = []})) in
			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (frontend_path ^ "/" ^ x) y)
		        (("backend", backend_path) :: frontend_list) in
			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (backend_path ^ "/" ^ x) y)
				(("frontend", frontend_path) :: backend_list) in
			lwt () = mkdir xs private_data_path in
			lwt () = setperms xs private_data_path (Xs_protocol.ACL.({owner = device.backend.domid; other = NONE; acl = []})) in
			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (private_data_path ^ "/" ^ x) y)
				(("backend-kind", string_of_kind device.backend.kind) ::
					("backend-id", string_of_int device.backend.domid) :: private_list) in
			return ()
		) in
	return ()
end

module Domain = struct

let make domid client =
	(* create /local/domain/<domid> *)
	(* create 3 VBDs, 1 VIF (workaround transaction problem?) *)
	lwt dom_path = getdomainpath domid client in
	let uuid = Printf.sprintf "uuid-%d" domid in
	let name = "name" in
	let vm_path = prefix ^ "/vm/" ^ uuid in
	let vss_path = prefix ^ "/vss/" ^ uuid in
	let xsdata = [
		"xsdata", "xsdata"
	] in
	let platformdata = [
		"platformdata", "platformdata"
	] in
	let bios_strings = [
		"bios_strings", "bios_strings"
	] in
	let roperm = Xs_protocol.ACL.({owner = 0; other = NONE; acl = [ domid, READ ]}) in
	let rwperm = Xs_protocol.ACL.({owner = domid; other = NONE; acl = []}) in
	lwt () =
		with_xst client
			(fun xs ->
				(* Clear any existing rubbish in xenstored *)
				lwt () = try_lwt lwt _ = rm xs dom_path in return () with _ -> return () in
				lwt () = mkdir xs dom_path in
				lwt () = setperms xs dom_path roperm in
				(* The /vm path needs to be shared over a localhost migrate *)
				lwt vm_exists = with_xs client (exists vm_path) in
				lwt () = if not vm_exists then begin
					lwt () = mkdir xs vm_path in
					lwt () = setperms xs vm_path roperm in
					lwt () = write xs (vm_path ^ "/uuid") uuid in
					lwt () = write xs (vm_path ^ "/name") name in
					return ()
				end else return () in
				lwt () = write xs (Printf.sprintf "%s/domains/%d" vm_path domid) dom_path in

				lwt () = mkdir xs vss_path in
				lwt () = setperms xs vss_path rwperm in

				lwt () = write xs (dom_path ^ "/vm") vm_path in
				lwt () = write xs (dom_path ^ "/vss") vss_path in
				lwt () = write xs (dom_path ^ "/name") name in

				(* create cpu and memory directory with read only perms *)
				lwt () = Lwt_list.iter_s (fun dir ->
					let ent = Printf.sprintf "%s/%s" dom_path dir in
					lwt () = mkdir xs ent in
					setperms xs ent roperm
				) [ "cpu"; "memory" ] in
				(* create read/write nodes for the guest to use *)
				lwt () = Lwt_list.iter_s (fun dir ->
					let ent = Printf.sprintf "%s/%s" dom_path dir in
					lwt () = mkdir xs ent in
					setperms xs ent rwperm
				) [ "device"; "error"; "drivers"; "control"; "attr"; "data"; "messages"; "vm-data" ] in
				return ()
		) in
	lwt () = with_xs client
		(fun xs ->

			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (dom_path ^ "/" ^ x) y) xsdata in

			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (dom_path ^ "/platform/" ^ x) y) platformdata in
			lwt () = Lwt_list.iter_s (fun (x, y) -> write xs (dom_path ^ "/bios-strings/" ^ x) y) bios_strings in
	
			(* If a toolstack sees a domain which it should own in this state then the
			   domain is not completely setup and should be shutdown. *)
			lwt () = write xs (dom_path ^ "/action-request") "poweroff" in

			lwt () = write xs (dom_path ^ "/control/platform-feature-multiprocessor-suspend") "1" in

			(* CA-30811: let the linux guest agent easily determine if this is a fresh domain even if
			   the domid hasn't changed (consider cross-host migrate) *)
			lwt () = write xs (dom_path ^ "/unique-domain-id") uuid in
			return ()
		) in
	return ()

let control_shutdown domid client =
	getdomainpath domid client >|= (fun x -> x ^ "/control/shutdown")

let string_of_shutdown_reason _ = "halt"

let get_uuid domid = Printf.sprintf "uuid-%d" domid

(** Request a shutdown, return without waiting for acknowledgement *)
let shutdown domid req client =
	let reason = string_of_shutdown_reason req in
	lwt path = control_shutdown domid client in
	lwt dom_path = getdomainpath domid client in
	with_xst client
		(fun xs ->
			(* Fail if the directory has been deleted *)
			lwt domain_exists = with_xs client (exists dom_path) in
			if domain_exists then begin
				lwt () = write xs path reason in
				return true
			end else return false
		)

let destroy domid client =
	lwt dom_path = getdomainpath domid client in
	(* These are the devices with a frontend in [domid] and a well-formed backend
	   in some other domain *)
	lwt all_devices = Device.list_frontends domid client in
	
	(* Forcibly shutdown every backend *)
	lwt () = Lwt_list.iter_s
		(fun device ->
			Device.hard_shutdown device client
		) all_devices in
	(* Remove our reference to the /vm/<uuid> directory *)
	lwt vm_path = with_xs client (read_opt (dom_path ^ "/vm")) in
	lwt vss_path = with_xs client (read_opt (dom_path ^ "/vss")) in
	lwt () = begin match vm_path with
		| Some vm_path ->
			with_xs client
				(fun xs ->
					lwt () = rm xs (vm_path ^ "/domains/" ^ (string_of_int domid)) in
					lwt domains = readdir (vm_path ^ "/domains") client in
					if List.filter (fun x -> x <> "") domains = [] then begin
						lwt () = rm xs vm_path in
						begin match vss_path with
							| Some vss_path -> rm xs vss_path
							| None -> return ()
						end
					end else return ()
				)
		| None -> return ()
	end in
	lwt () = with_xs client (fun xs -> rm xs dom_path) in
	lwt backend_path = getdomainpath 0 client >|= (fun x -> x ^ "/backend") in
	lwt all_backend_types = readdir backend_path client in
	lwt () = Lwt_list.iter_s
		(fun ty ->
			with_xs client (fun xs -> rm xs (Printf.sprintf "%s/%s/%d" backend_path ty domid))
		) all_backend_types in
	return ()
end

let vm_shutdown domid client =
	lwt _ = Domain.shutdown domid () client in
	Domain.destroy domid client

let vm_start domid client =
	let vbd devid = {
		Device.frontend = { Device.domid = domid; kind = Device.Vbd; devid = 0 };
		backend = { Device.domid = 0; kind = Device.Vbd; devid = 0 }
	} in
	lwt () = Domain.make domid client in
	Lwt_list.iter_s (fun d -> Device.add d client) [ vbd 0; vbd 1; vbd 2 ]

let vm_cycle domid client =
	lwt () = vm_start domid client in
	vm_shutdown domid client

let rec between start finish =
	if start > finish
	then []
	else start :: (between (start + 1) finish)

let sequential n client : unit Lwt.t =
	Lwt_list.iter_s
		(fun domid ->
		   vm_cycle domid client
		) (between 0 n)

let parallel n client =
	Lwt_list.iter_p
		(fun domid ->
			vm_cycle domid client
		) (between 0 n)

let query m n client =
	lwt () = Lwt_list.iter_s
	(fun domid -> 
		vm_start domid client
	) (between 0 n) in
	lwt () = for_lwt i = 0 to m do
		Lwt_list.iter_p
		(fun domid ->
			with_xs client (fun xs -> lwt _ = read xs (Printf.sprintf "%s/local/domain/%d/name" prefix domid) in return ())
		) (between 0 n)
	done in
	lwt () = Lwt_list.iter_s
	(fun domid -> 
		vm_shutdown domid client
	) (between 0 n) in
	return ()


let time f =
	let start = Unix.gettimeofday () in
	lwt () = f () in
	return (Unix.gettimeofday () -. start)

let usage () =
  let bin x = Sys.argv.(0) ^ x in
  let lines = [
    bin " : a xenstore benchmark tool";
    "";
    "Usage:";
	bin " [-path /var/run/xenstored/socket] [-n number of vms]";
  ] in
  List.iter (fun x -> Printf.fprintf stderr "%s\n" x) lines

let main () =
  let verbose = ref false in
  let args = Sys.argv |> Array.to_list |> List.tl in
  (* Look for "-h" or "-v" arguments *)
  if List.mem "-h" args then begin
    usage ();
    return ();
  end else begin
    verbose := List.mem "-v" args;
    let args = List.filter (fun x -> x <> "-v") args in
    (* Extract any -path X argument *)
	let extract args key =
		let result = ref None in
		let args =
			List.fold_left (fun (acc, foundit) x ->
				if foundit then (result := Some x; (acc, false))
				else if x = key then (acc, true)
				else (x :: acc, false)
			) ([], false) args |> fst |> List.rev in
		!result, args in
	let path, args = extract args "-path" in
	begin match path with
	| Some path -> Xs_transport.xenstored_socket := path
	| None -> ()
	end;
	let n, args = extract args "-n" in
	let n = match n with
		| None -> 300
		| Some n -> int_of_string n in

	lwt client = make () in

	lwt t = time (fun () -> sequential n client) in
    lwt () = Lwt_io.write Lwt_io.stdout (Printf.sprintf "%d sequential starts and shutdowns: %.02f\n" n t) in

	lwt t = time (fun () -> parallel n client) in
    lwt () = Lwt_io.write Lwt_io.stdout (Printf.sprintf "%d parallel starts and shutdowns: %.02f\n" n t) in
	lwt t = time (fun () -> query 1000 n client) in
    lwt () = Lwt_io.write Lwt_io.stdout (Printf.sprintf "%d read queries per %d VMs: %.02f\n" 1000 n t) in

	return ()
 end

let _ =
  Lwt_main.run (main ())
