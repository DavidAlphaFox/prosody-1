local configmanager = require "core.configmanager";
local show_usage = require "util.prosodyctl".show_usage;
local show_warning = require "util.prosodyctl".show_warning;
local is_prosody_running = require "util.prosodyctl".isrunning;
local parse_args = require "util.argparse".parse;
local dependencies = require "util.dependencies";
local socket = require "socket";
local socket_url = require "socket.url";
local jid_split = require "util.jid".prepped_split;
local modulemanager = require "core.modulemanager";
local async = require "util.async";
local httputil = require "util.http";

local function check_ojn(check_type, target_host)
	local http = require "net.http"; -- .new({});
	local json = require "util.json";

	local response, err = async.wait_for(http.request(
		("https://observe.jabber.network/api/v1/check/%s"):format(httputil.urlencode(check_type)),
		{
			method="POST",
			headers={["Accept"] = "application/json"; ["Content-Type"] = "application/json"},
			body=json.encode({target=target_host}),
		}));

	if not response then
		return false, err;
	end

	if response.code ~= 200 then
		return false, ("API replied with non-200 code: %d"):format(response.code);
	end

	local decoded_body, err = json.decode(response.body);
	if decoded_body == nil then
		return false, ("Failed to parse API JSON: %s"):format(err)
	end

	local success = decoded_body["success"];
	return success == true, nil;
end

local function check_probe(base_url, probe_module, target)
	local http = require "net.http"; -- .new({});
	local params = httputil.formencode({ module = probe_module; target = target })
	local response, err = async.wait_for(http.request(base_url .. "?" .. params));

	if not response then return false, err; end

	if response.code ~= 200 then return false, ("API replied with non-200 code: %d"):format(response.code); end

	for line in response.body:gmatch("[^\r\n]+") do
		local probe_success = line:match("^probe_success%s+(%d+)");

		if probe_success == "1" then
			return true;
		elseif probe_success == "0" then
			return false;
		end
	end
	return false, "Probe endpoint did not return a success status";
end

local function check_turn_service(turn_service, ping_service)
	local ip = require "util.ip";
	local stun = require "net.stun";

	-- Create UDP socket for communication with the server
	local sock = assert(require "socket".udp());
	sock:setsockname("*", 0);
	sock:setpeername(turn_service.host, turn_service.port);
	sock:settimeout(10);

	-- Helper function to receive a packet
	local function receive_packet()
		local raw_packet, err = sock:receive();
		if not raw_packet then
			return nil, err;
		end
		return stun.new_packet():deserialize(raw_packet);
	end

	local result = { warnings = {} };

	-- Send a "binding" query, i.e. a request for our external IP/port
	local bind_query = stun.new_packet("binding", "request");
	bind_query:add_attribute("software", "prosodyctl check turn");
	sock:send(bind_query:serialize());

	local bind_result, err = receive_packet();
	if not bind_result then
		result.error = "No STUN response: "..err;
		return result;
	elseif bind_result:is_err_resp() then
		result.error = ("STUN server returned error: %d (%s)"):format(bind_result:get_error());
		return result;
	elseif not bind_result:is_success_resp() then
		result.error = ("Unexpected STUN response: %d (%s)"):format(bind_result:get_type());
		return result;
	end

	result.external_ip = bind_result:get_xor_mapped_address();
	if not result.external_ip then
		result.error = "STUN server did not return an address";
		return result;
	end
	if ip.new_ip(result.external_ip.address).private then
		table.insert(result.warnings, "STUN returned a private IP! Is the TURN server behind a NAT and misconfigured?");
	end

	-- Send a TURN "allocate" request. Expected to fail due to auth, but
	-- necessary to obtain a valid realm/nonce from the server.
	local pre_request = stun.new_packet("allocate", "request");
	sock:send(pre_request:serialize());

	local pre_result, err = receive_packet();
	if not pre_result then
		result.error = "No initial TURN response: "..err;
		return result;
	elseif pre_result:is_success_resp() then
		result.error = "TURN server does not have authentication enabled";
		return result;
	end

	local realm = pre_result:get_attribute("realm");
	local nonce = pre_result:get_attribute("nonce");

	if not realm then
		table.insert(result.warnings, "TURN server did not return an authentication realm. Is authentication enabled?");
	end
	if not nonce then
		table.insert(result.warnings, "TURN server did not return a nonce");
	end

	-- Use the configured secret to obtain temporary user/pass credentials
	local turn_user, turn_pass = stun.get_user_pass_from_secret(turn_service.secret);

	-- Send a TURN allocate request, will fail if auth is wrong
	local alloc_request = stun.new_packet("allocate", "request");
	alloc_request:add_requested_transport("udp");
	alloc_request:add_attribute("username", turn_user);
	if realm then
		alloc_request:add_attribute("realm", realm);
	end
	if nonce then
		alloc_request:add_attribute("nonce", nonce);
	end
	local key = stun.get_long_term_auth_key(realm or turn_service.host, turn_user, turn_pass);
	alloc_request:add_message_integrity(key);
	sock:send(alloc_request:serialize());

	-- Check the response
	local alloc_response, err = receive_packet();
	if not alloc_response then
		result.error = "TURN server did not response to allocation request: "..err;
		return result;
	elseif alloc_response:is_err_resp() then
		result.error = ("TURN server failed to create allocation: %d (%s)"):format(alloc_response:get_error());
		return result;
	elseif not alloc_response:is_success_resp() then
		result.error = ("Unexpected TURN response: %d (%s)"):format(alloc_response:get_type());
		return result;
	end

	result.relayed_addresses = alloc_response:get_xor_relayed_addresses();

	if not ping_service then
		-- Success! We won't be running the relay test.
		return result;
	end

	-- Run the relay test - i.e. send a binding request to ping_service
	-- and receive a response.

	-- Resolve the IP of the ping service
	local ping_host, ping_port = ping_service:match("^([^:]+):(%d+)$");
	if ping_host then
		ping_port = tonumber(ping_port);
	else
		-- Only a hostname specified, use default STUN port
		ping_host, ping_port = ping_service, 3478;
	end

	if ping_host == turn_service.host then
		result.error = ("Unable to perform ping test: please supply an external STUN server address. See https://prosody.im/doc/turn#prosodyctl-check");
		return result;
	end

	local ping_service_ip, err = socket.dns.toip(ping_host);
	if not ping_service_ip then
		result.error = "Unable to resolve ping service hostname: "..err;
		return result;
	end

	-- Ask the TURN server to allow packets from the ping service IP
	local perm_request = stun.new_packet("create-permission");
	perm_request:add_xor_peer_address(ping_service_ip);
	perm_request:add_attribute("username", turn_user);
	if realm then
		perm_request:add_attribute("realm", realm);
	end
	if nonce then
		perm_request:add_attribute("nonce", nonce);
	end
	perm_request:add_message_integrity(key);
	sock:send(perm_request:serialize());

	local perm_response, err = receive_packet();
	if not perm_response then
		result.error = "No response from TURN server when requesting peer permission: "..err;
		return result;
	elseif perm_response:is_err_resp() then
		result.error = ("TURN permission request failed: %d (%s)"):format(perm_response:get_error());
		return result;
	elseif not perm_response:is_success_resp() then
		result.error = ("Unexpected TURN response: %d (%s)"):format(perm_response:get_type());
		return result;
	end

	-- Ask the TURN server to relay a STUN binding request to the ping server
	local ping_data = stun.new_packet("binding"):serialize();

	local ping_request = stun.new_packet("send", "indication");
	ping_request:add_xor_peer_address(ping_service_ip, ping_port);
	ping_request:add_attribute("data", ping_data);
	ping_request:add_attribute("username", turn_user);
	if realm then
		ping_request:add_attribute("realm", realm);
	end
	if nonce then
		ping_request:add_attribute("nonce", nonce);
	end
	ping_request:add_message_integrity(key);
	sock:send(ping_request:serialize());

	local ping_response, err = receive_packet();
	if not ping_response then
		result.error = "No response from ping server ("..ping_service_ip.."): "..err;
		return result;
	elseif not ping_response:is_indication() or select(2, ping_response:get_method()) ~= "data" then
		result.error = ("Unexpected TURN response: %s %s"):format(select(2, ping_response:get_method()), select(2, ping_response:get_type()));
		return result;
	end

	local pong_data = ping_response:get_attribute("data");
	if not pong_data then
		result.error = "No data relayed from remote server";
		return result;
	end
	local pong = stun.new_packet():deserialize(pong_data);

	result.external_ip_pong = pong:get_xor_mapped_address();
	if not result.external_ip_pong then
		result.error = "Ping server did not return an address";
		return result;
	end

	local relay_address_found, relay_port_matches;
	for _, relayed_address in ipairs(result.relayed_addresses) do
		if relayed_address.address == result.external_ip_pong.address then
			relay_address_found = true;
			relay_port_matches = result.external_ip_pong.port == relayed_address.port;
		end
	end
	if not relay_address_found then
		table.insert(result.warnings, "TURN external IP vs relay address mismatch! Is the TURN server behind a NAT and misconfigured?");
	elseif not relay_port_matches then
		table.insert(result.warnings, "External port does not match reported relay port! This is probably caused by a NAT in front of the TURN server.");
	end

	--

	return result;
end

local function skip_bare_jid_hosts(host)
	if jid_split(host) then
		-- See issue #779
		return false;
	end
	return true;
end

local check_opts = {
	short_params = {
		h = "help", v = "verbose";
	};
	value_params = {
		ping = true;
	};
};

local function check(arg)
	if arg[1] == "help" or arg[1] == "--help" then
		show_usage([[check]], [[Perform basic checks on your Prosody installation]]);
		return 1;
	end
	local what = table.remove(arg, 1);
	local opts, opts_err, opts_info = parse_args(arg, check_opts);
	if opts_err == "missing-value" then
		print("Error: Expected a value after '"..opts_info.."'");
		return 1;
	elseif opts_err == "param-not-found" then
		print("Error: Unknown parameter: "..opts_info);
		return 1;
	end
	local array = require "util.array";
	local set = require "util.set";
	local it = require "util.iterators";
	local ok = true;
	local function disabled_hosts(host, conf) return host ~= "*" and conf.enabled ~= false; end
	local function enabled_hosts() return it.filter(disabled_hosts, pairs(configmanager.getconfig())); end
	if not (what == nil or what == "disabled" or what == "config" or what == "dns" or what == "certs" or what == "connectivity" or what == "turn") then
		show_warning("Don't know how to check '%s'. Try one of 'config', 'dns', 'certs', 'disabled', 'turn' or 'connectivity'.", what);
		show_warning("Note: The connectivity check will connect to a remote server.");
		return 1;
	end
	if not what or what == "disabled" then
		local disabled_hosts_set = set.new();
		for host, host_options in it.filter("*", pairs(configmanager.getconfig())) do
			if host_options.enabled == false then
				disabled_hosts_set:add(host);
			end
		end
		if not disabled_hosts_set:empty() then
			local msg = "Checks will be skipped for these disabled hosts: %s";
			if what then msg = "These hosts are disabled: %s"; end
			show_warning(msg, tostring(disabled_hosts_set));
			if what then return 0; end
			print""
		end
	end
	if not what or what == "config" then
		print("Checking config...");

		if what == "config" then
			local files = configmanager.files();
			print("    The following configuration files have been loaded:");
			print("      -  "..table.concat(files, "\n      -  "));
		end

		local obsolete = set.new({ --> remove
			"archive_cleanup_interval",
			"cross_domain_bosh",
			"cross_domain_websocket",
			"dns_timeout",
			"muc_log_cleanup_interval",
			"s2s_dns_resolvers",
			"setgid",
			"setuid",
		});
		local function instead_use(kind, name, value)
			if kind == "option" then
				if value then
					return string.format("instead, use '%s = %q'", name, value);
				else
					return string.format("instead, use '%s'", name);
				end
			elseif kind == "module" then
				return string.format("instead, add %q to '%s'", name, value or "modules_enabled");
			elseif kind == "community" then
				return string.format("instead, add %q from %s", name, value or "prosody-modules");
			end
			return kind
		end
		local deprecated_replacements = {
			anonymous_login = instead_use("option", "authentication", "anonymous");
			daemonize = "instead, use the --daemonize/-D or --foreground/-F command line flags";
			disallow_s2s = instead_use("module", "s2s");
			no_daemonize = "instead, use the --daemonize/-D or --foreground/-F command line flags";
			require_encryption = "instead, use 'c2s_require_encryption' and 's2s_require_encryption'";
			vcard_compatibility = instead_use("community", "mod_compat_vcard");
			use_libevent = instead_use("option", "network_backend", "event");
			whitelist_registration_only = instead_use("option", "allowlist_registration_only");
			registration_whitelist = instead_use("option", "registration_allowlist");
			registration_blacklist = instead_use("option", "registration_blocklist");
			blacklist_on_registration_throttle_overload = instead_use("blocklist_on_registration_throttle_overload");
		};
		-- FIXME all the singular _port and _interface options are supposed to be deprecated too
		local deprecated_ports = { bosh = "http", legacy_ssl = "c2s_direct_tls" };
		local port_suffixes = set.new({ "port", "ports", "interface", "interfaces", "ssl" });
		for port, replacement in pairs(deprecated_ports) do
			for suffix in port_suffixes do
				local rsuffix = (suffix == "port" or suffix == "interface") and suffix.."s" or suffix;
				deprecated_replacements[port.."_"..suffix] = "instead, use '"..replacement.."_"..rsuffix.."'"
			end
		end
		local deprecated = set.new(array.collect(it.keys(deprecated_replacements)));
		local known_global_options = set.new({
			"access_control_allow_credentials",
			"access_control_allow_headers",
			"access_control_allow_methods",
			"access_control_max_age",
			"admin_socket",
			"body_size_limit",
			"bosh_max_inactivity",
			"bosh_max_polling",
			"bosh_max_wait",
			"buffer_size_limit",
			"c2s_close_timeout",
			"c2s_stanza_size_limit",
			"c2s_tcp_keepalives",
			"c2s_timeout",
			"component_stanza_size_limit",
			"component_tcp_keepalives",
			"consider_bosh_secure",
			"consider_websocket_secure",
			"console_banner",
			"console_prettyprint_settings",
			"daemonize",
			"gc",
			"http_default_host",
			"http_errors_always_show",
			"http_errors_default_message",
			"http_errors_detailed",
			"http_errors_messages",
			"http_max_buffer_size",
			"http_max_content_size",
			"installer_plugin_path",
			"limits",
			"limits_resolution",
			"log",
			"multiplex_buffer_size",
			"network_backend",
			"network_default_read_size",
			"network_settings",
			"openmetrics_allow_cidr",
			"openmetrics_allow_ips",
			"pidfile",
			"plugin_paths",
			"plugin_server",
			"prosodyctl_timeout",
			"prosody_group",
			"prosody_user",
			"run_as_root",
			"s2s_close_timeout",
			"s2s_insecure_domains",
			"s2s_require_encryption",
			"s2s_secure_auth",
			"s2s_secure_domains",
			"s2s_stanza_size_limit",
			"s2s_tcp_keepalives",
			"s2s_timeout",
			"statistics",
			"statistics_config",
			"statistics_interval",
			"tcp_keepalives",
			"tls_profile",
			"trusted_proxies",
			"umask",
			"use_dane",
			"use_ipv4",
			"use_ipv6",
			"websocket_frame_buffer_limit",
			"websocket_frame_fragment_limit",
			"websocket_get_response_body",
			"websocket_get_response_text",
		});
		local config = configmanager.getconfig();
		-- Check that we have any global options (caused by putting a host at the top)
		if it.count(it.filter("log", pairs(config["*"]))) == 0 then
			ok = false;
			print("");
			print("    No global options defined. Perhaps you have put a host definition at the top")
			print("    of the config file? They should be at the bottom, see https://prosody.im/doc/configure#overview");
		end
		if it.count(enabled_hosts()) == 0 then
			ok = false;
			print("");
			if it.count(it.filter("*", pairs(config))) == 0 then
				print("    No hosts are defined, please add at least one VirtualHost section")
			elseif config["*"]["enabled"] == false then
				print("    No hosts are enabled. Remove enabled = false from the global section or put enabled = true under at least one VirtualHost section")
			else
				print("    All hosts are disabled. Remove enabled = false from at least one VirtualHost section")
			end
		end
		if not config["*"].modules_enabled then
			print("    No global modules_enabled is set?");
			local suggested_global_modules;
			for host, options in enabled_hosts() do --luacheck: ignore 213/host
				if not options.component_module and options.modules_enabled then
					suggested_global_modules = set.intersection(suggested_global_modules or set.new(options.modules_enabled), set.new(options.modules_enabled));
				end
			end
			if suggested_global_modules and not suggested_global_modules:empty() then
				print("    Consider moving these modules into modules_enabled in the global section:")
				print("    "..tostring(suggested_global_modules / function (x) return ("%q"):format(x) end));
			end
			print();
		end

		do -- Check for modules enabled both normally and as components
			local modules = set.new(config["*"]["modules_enabled"]);
			for host, options in enabled_hosts() do
				local component_module = options.component_module;
				if component_module and modules:contains(component_module) then
					print(("    mod_%s is enabled both in modules_enabled and as Component %q %q"):format(component_module, host, component_module));
					print("    This means the service is enabled on all VirtualHosts as well as the Component.");
					print("    Are you sure this what you want? It may cause unexpected behaviour.");
				end
			end
		end

		-- Check for global options under hosts
		local global_options = set.new(it.to_array(it.keys(config["*"])));
		local obsolete_global_options = set.intersection(global_options, obsolete);
		if not obsolete_global_options:empty() then
			print("");
			print("    You have some obsolete options you can remove from the global section:");
			print("    "..tostring(obsolete_global_options))
			ok = false;
		end
		local deprecated_global_options = set.intersection(global_options, deprecated);
		if not deprecated_global_options:empty() then
			print("");
			print("    You have some deprecated options in the global section:");
			for option in deprecated_global_options do
				print(("    '%s' -- %s"):format(option, deprecated_replacements[option]));
			end
			ok = false;
		end
		for host, options in it.filter(function (h) return h ~= "*" end, pairs(configmanager.getconfig())) do
			local host_options = set.new(it.to_array(it.keys(options)));
			local misplaced_options = set.intersection(host_options, known_global_options);
			for name in pairs(options) do
				if name:match("^interfaces?")
				or name:match("_ports?$") or name:match("_interfaces?$")
				or (name:match("_ssl$") and not name:match("^[cs]2s_ssl$")) then
					misplaced_options:add(name);
				end
			end
			-- FIXME These _could_ be misplaced, but we would have to check where the corresponding module is loaded to be sure
			misplaced_options:exclude(set.new({ "external_service_port", "turn_external_port" }));
			if not misplaced_options:empty() then
				ok = false;
				print("");
				local n = it.count(misplaced_options);
				print("    You have "..n.." option"..(n>1 and "s " or " ").."set under "..host.." that should be");
				print("    in the global section of the config file, above any VirtualHost or Component definitions,")
				print("    see https://prosody.im/doc/configure#overview for more information.")
				print("");
				print("    You need to move the following option"..(n>1 and "s" or "")..": "..table.concat(it.to_array(misplaced_options), ", "));
			end
		end
		for host, options in enabled_hosts() do
			local host_options = set.new(it.to_array(it.keys(options)));
			local subdomain = host:match("^[^.]+");
			if not(host_options:contains("component_module")) and (subdomain == "jabber" or subdomain == "xmpp"
			   or subdomain == "chat" or subdomain == "im") then
				print("");
				print("    Suggestion: If "..host.. " is a new host with no real users yet, consider renaming it now to");
				print("     "..host:gsub("^[^.]+%.", "")..". You can use SRV records to redirect XMPP clients and servers to "..host..".");
				print("     For more information see: https://prosody.im/doc/dns");
			end
		end
		local all_modules = set.new(config["*"].modules_enabled);
		local all_options = set.new(it.to_array(it.keys(config["*"])));
		for host in enabled_hosts() do
			all_options:include(set.new(it.to_array(it.keys(config[host]))));
			all_modules:include(set.new(config[host].modules_enabled));
		end
		for mod in all_modules do
			if mod:match("^mod_") then
				print("");
				print("    Modules in modules_enabled should not have the 'mod_' prefix included.");
				print("    Change '"..mod.."' to '"..mod:match("^mod_(.*)").."'.");
			elseif mod:match("^auth_") then
				print("");
				print("    Authentication modules should not be added to modules_enabled,");
				print("    but be specified in the 'authentication' option.");
				print("    Remove '"..mod.."' from modules_enabled and instead add");
				print("        authentication = '"..mod:match("^auth_(.*)").."'");
				print("    For more information see https://prosody.im/doc/authentication");
			elseif mod:match("^storage_") then
				print("");
				print("    storage modules should not be added to modules_enabled,");
				print("    but be specified in the 'storage' option.");
				print("    Remove '"..mod.."' from modules_enabled and instead add");
				print("        storage = '"..mod:match("^storage_(.*)").."'");
				print("    For more information see https://prosody.im/doc/storage");
			end
		end
		if all_modules:contains("vcard") and all_modules:contains("vcard_legacy") then
			print("");
			print("    Both mod_vcard_legacy and mod_vcard are enabled but they conflict");
			print("    with each other. Remove one.");
		end
		if all_modules:contains("pep") and all_modules:contains("pep_simple") then
			print("");
			print("    Both mod_pep_simple and mod_pep are enabled but they conflict");
			print("    with each other. Remove one.");
		end
		for host, host_config in pairs(config) do --luacheck: ignore 213/host
			if type(rawget(host_config, "storage")) == "string" and rawget(host_config, "default_storage") then
				print("");
				print("    The 'default_storage' option is not needed if 'storage' is set to a string.");
				break;
			end
		end
		local require_encryption = set.intersection(all_options, set.new({
			"require_encryption", "c2s_require_encryption", "s2s_require_encryption"
		})):empty();
		local ssl = dependencies.softreq"ssl";
		if not ssl then
			if not require_encryption then
				print("");
				print("    You require encryption but LuaSec is not available.");
				print("    Connections will fail.");
				ok = false;
			end
		elseif not ssl.loadcertificate then
			if all_options:contains("s2s_secure_auth") then
				print("");
				print("    You have set s2s_secure_auth but your version of LuaSec does ");
				print("    not support certificate validation, so all s2s connections will");
				print("    fail.");
				ok = false;
			elseif all_options:contains("s2s_secure_domains") then
				local secure_domains = set.new();
				for host in enabled_hosts() do
					if config[host].s2s_secure_auth == true then
						secure_domains:add("*");
					else
						secure_domains:include(set.new(config[host].s2s_secure_domains));
					end
				end
				if not secure_domains:empty() then
					print("");
					print("    You have set s2s_secure_domains but your version of LuaSec does ");
					print("    not support certificate validation, so s2s connections to/from ");
					print("    these domains will fail.");
					ok = false;
				end
			end
		elseif require_encryption and not all_modules:contains("tls") then
			print("");
			print("    You require encryption but mod_tls is not enabled.");
			print("    Connections will fail.");
			ok = false;
		end

		do
			local global_modules = set.new(config["*"].modules_enabled);
			local registration_enabled_hosts = {};
			for host in enabled_hosts() do
				local host_modules = set.new(config[host].modules_enabled) + global_modules;
				local allow_registration = config[host].allow_registration;
				local mod_register = host_modules:contains("register");
				local mod_register_ibr = host_modules:contains("register_ibr");
				local mod_invites_register = host_modules:contains("invites_register");
				local registration_invite_only = config[host].registration_invite_only;
				local is_vhost = not config[host].component_module;
				if is_vhost and (mod_register_ibr or (mod_register and allow_registration))
				   and not (mod_invites_register and registration_invite_only) then
					table.insert(registration_enabled_hosts, host);
				end
			end
			if #registration_enabled_hosts > 0 then
				table.sort(registration_enabled_hosts);
				print("");
				print("    Public registration is enabled on:");
				print("        "..table.concat(registration_enabled_hosts, ", "));
				print("");
				print("        If this is intentional, review our guidelines on running a public server");
				print("        at https://prosody.im/doc/public_servers - otherwise, consider switching to");
				print("        invite-based registration, which is more secure.");
			end
		end

		do
			local orphan_components = {};
			local referenced_components = set.new();
			local enabled_hosts_set = set.new();
			for host, host_options in it.filter("*", pairs(configmanager.getconfig())) do
				if host_options.enabled ~= false then
					enabled_hosts_set:add(host);
					for _, disco_item in ipairs(host_options.disco_items or {}) do
						referenced_components:add(disco_item[1]);
					end
				end
			end
			for host, host_config in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
				local is_component = not not host_config.component_module;
				if is_component then
					local parent_domain = host:match("^[^.]+%.(.+)$");
					local is_orphan = not (enabled_hosts_set:contains(parent_domain) or referenced_components:contains(host));
					if is_orphan then
						table.insert(orphan_components, host);
					end
				end
			end
			if #orphan_components > 0 then
				table.sort(orphan_components);
				print("");
				print("    Your configuration contains the following unreferenced components:\n");
				print("        "..table.concat(orphan_components, "\n        "));
				print("");
				print("    Clients may not be able to discover these services because they are not linked to");
				print("    any VirtualHost. They are automatically linked if they are direct subdomains of a");
				print("    VirtualHost. Alternatively, you can explicitly link them using the disco_items option.");
				print("    For more information see https://prosody.im/doc/modules/mod_disco#items");
			end
		end

		print("Done.\n");
	end
	if not what or what == "dns" then
		local dns = require "net.dns";
		pcall(function ()
			local unbound = require"net.unbound";
			dns = unbound.dns;
		end)
		local idna = require "util.encodings".idna;
		local ip = require "util.ip";
		local c2s_ports = set.new(configmanager.get("*", "c2s_ports") or {5222});
		local s2s_ports = set.new(configmanager.get("*", "s2s_ports") or {5269});
		local c2s_tls_ports = set.new(configmanager.get("*", "c2s_direct_tls_ports") or {});
		local s2s_tls_ports = set.new(configmanager.get("*", "s2s_direct_tls_ports") or {});

		if set.new(configmanager.get("*", "modules_enabled")):contains("net_multiplex") then
			local multiplex_ports = set.new(configmanager.get("*", "ports") or {});
			local multiplex_tls_ports = set.new(configmanager.get("*", "ssl_ports") or {});
			if not multiplex_ports:empty() then
				c2s_ports = c2s_ports + multiplex_ports;
				s2s_ports = s2s_ports + multiplex_ports;
			end
			if not multiplex_tls_ports:empty() then
				c2s_tls_ports = c2s_tls_ports + multiplex_tls_ports;
				s2s_tls_ports = s2s_tls_ports + multiplex_tls_ports;
			end
		end

		local c2s_srv_required, s2s_srv_required, c2s_tls_srv_required, s2s_tls_srv_required;
		if not c2s_ports:contains(5222) then
			c2s_srv_required = true;
		end
		if not s2s_ports:contains(5269) then
			s2s_srv_required = true;
		end
		if not c2s_tls_ports:empty() then
			c2s_tls_srv_required = true;
		end
		if not s2s_tls_ports:empty() then
			s2s_tls_srv_required = true;
		end

		local problem_hosts = set.new();

		local external_addresses, internal_addresses = set.new(), set.new();

		local fqdn = socket.dns.tohostname(socket.dns.gethostname());
		if fqdn then
			do
				local res = dns.lookup(idna.to_ascii(fqdn), "A");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.a);
					end
				end
			end
			do
				local res = dns.lookup(idna.to_ascii(fqdn), "AAAA");
				if res then
					for _, record in ipairs(res) do
						external_addresses:add(record.aaaa);
					end
				end
			end
		end

		local local_addresses = require"util.net".local_addresses() or {};

		for addr in it.values(local_addresses) do
			if not ip.new_ip(addr).private then
				external_addresses:add(addr);
			else
				internal_addresses:add(addr);
			end
		end

		-- Allow admin to specify additional (e.g. undiscoverable) IP addresses in the config
		for _, address in ipairs(configmanager.get("*", "external_addresses") or {}) do
			external_addresses:add(address);
		end

		if external_addresses:empty() then
			print("");
			print("   Failed to determine the external addresses of this server. Checks may be inaccurate.");
			c2s_srv_required, s2s_srv_required = true, true;
		end

		local v6_supported = not not socket.tcp6;
		local use_ipv4 = configmanager.get("*", "use_ipv4") ~= false;
		local use_ipv6 = v6_supported and configmanager.get("*", "use_ipv6") ~= false;

		local function trim_dns_name(n)
			return (n:gsub("%.$", ""));
		end

		local unknown_addresses = set.new();

		for jid, host_options in enabled_hosts() do
			local all_targets_ok, some_targets_ok = true, false;
			local node, host = jid_split(jid);

			local modules, component_module = modulemanager.get_modules_for_host(host);
			if component_module then
				modules:add(component_module);
			end

			-- TODO Refactor these DNS SRV checks since they are very similar
			-- FIXME Suggest concrete actionable steps to correct issues so that
			-- users don't have to copy-paste the message into the support chat and
			-- ask what to do about it.
			local is_component = not not host_options.component_module;
			print("Checking DNS for "..(is_component and "component" or "host").." "..jid.."...");
			if node then
				print("Only the domain part ("..host..") is used in DNS.")
			end
			local target_hosts = set.new();
			if modules:contains("c2s") then
				local res = dns.lookup("_xmpp-client._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_c2s is enabled?
							print("    'xmpp-client' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not c2s_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown client port: "..record.srv.port);
						end
					end
				else
					if c2s_srv_required then
						print("    No _xmpp-client SRV record found for "..host..", but it looks like you need one.");
						all_targets_ok = false;
					else
						target_hosts:add(host);
					end
				end
			end
			if modules:contains("c2s") then
				local res = dns.lookup("_xmpps-client._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_c2s is enabled?
							print("    'xmpps-client' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not c2s_tls_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown Direct TLS client port: "..record.srv.port);
						end
					end
				elseif c2s_tls_srv_required then
					print("    No _xmpps-client SRV record found for "..host..", but it looks like you need one.");
					all_targets_ok = false;
				end
			end
			if modules:contains("s2s") then
				local res = dns.lookup("_xmpp-server._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO Is this an error if mod_s2s is enabled?
							print("    'xmpp-server' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not s2s_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown server port: "..record.srv.port);
						end
					end
				else
					if s2s_srv_required then
						print("    No _xmpp-server SRV record found for "..host..", but it looks like you need one.");
						all_targets_ok = false;
					else
						target_hosts:add(host);
					end
				end
			end
			if modules:contains("s2s") then
				local res = dns.lookup("_xmpps-server._tcp."..idna.to_ascii(host)..".", "SRV");
				if res and #res > 0 then
					for _, record in ipairs(res) do
						if record.srv.target == "." then -- TODO is this an error if mod_s2s is enabled?
							print("    'xmpps-server' service disabled by pointing to '.'"); -- FIXME Explain better what this is
							break;
						end
						local target = trim_dns_name(record.srv.target);
						target_hosts:add(target);
						if not s2s_tls_ports:contains(record.srv.port) then
							print("    SRV target "..target.." contains unknown Direct TLS server port: "..record.srv.port);
						end
					end
				elseif s2s_tls_srv_required then
					print("    No _xmpps-server SRV record found for "..host..", but it looks like you need one.");
					all_targets_ok = false;
				end
			end
			if target_hosts:empty() then
				target_hosts:add(host);
			end

			if target_hosts:contains("localhost") then
				print("    Target 'localhost' cannot be accessed from other servers");
				target_hosts:remove("localhost");
			end

			local function check_address(target)
				local A, AAAA = dns.lookup(idna.to_ascii(target), "A"), dns.lookup(idna.to_ascii(target), "AAAA");
				local prob = {};
				if use_ipv4 and not (A and #A > 0) then table.insert(prob, "A"); end
				if use_ipv6 and not (AAAA and #AAAA > 0) then table.insert(prob, "AAAA"); end
				return prob;
			end

			if modules:contains("proxy65") then
				local proxy65_target = configmanager.get(host, "proxy65_address") or host;
				if type(proxy65_target) == "string" then
					local prob = check_address(proxy65_target);
					if #prob > 0 then
						print("    File transfer proxy "..proxy65_target.." has no "..table.concat(prob, "/")
						.." record. Create one or set 'proxy65_address' to the correct host/IP.");
					end
				else
					print("    proxy65_address for "..host.." should be set to a string, unable to perform DNS check");
				end
			end

			local known_http_modules = set.new { "bosh"; "http_files"; "http_file_share"; "http_openmetrics"; "websocket" };
			local function contains_match(hayset, needle)
				for member in hayset do if member:find(needle) then return true end end
			end

			if modules:contains("http") or not set.intersection(modules, known_http_modules):empty()
				or contains_match(modules, "^http_") or contains_match(modules, "_web$") then

				local http_host = configmanager.get(host, "http_host") or host;
				local http_internal_host = http_host;
				local http_url = configmanager.get(host, "http_external_url");
				if http_url then
					local url_parse = require "socket.url".parse;
					local external_url_parts = url_parse(http_url);
					if external_url_parts then
						http_host = external_url_parts.host;
					else
						print("    The 'http_external_url' setting is not a valid URL");
					end
				end

				local prob = check_address(http_host);
				if #prob > 1 then
					print("    HTTP service " .. http_host .. " has no " .. table.concat(prob, "/") .. " record. Create one or change "
									.. (http_url and "'http_external_url'" or "'http_host'").." to the correct host.");
				end

				if http_host ~= http_internal_host then
					print("    Ensure the reverse proxy sets the HTTP Host header to '" .. http_internal_host .. "'");
				end
			end

			if not use_ipv4 and not use_ipv6 then
				print("    Both IPv6 and IPv4 are disabled, Prosody will not listen on any ports");
				print("    nor be able to connect to any remote servers.");
				all_targets_ok = false;
			end

			for target_host in target_hosts do
				local host_ok_v4, host_ok_v6;
				do
					local res = dns.lookup(idna.to_ascii(target_host), "A");
					if res then
						for _, record in ipairs(res) do
							if external_addresses:contains(record.a) then
								some_targets_ok = true;
								host_ok_v4 = true;
							elseif internal_addresses:contains(record.a) then
								host_ok_v4 = true;
								some_targets_ok = true;
								print("    "..target_host.." A record points to internal address, external connections might fail");
							else
								print("    "..target_host.." A record points to unknown address "..record.a);
								unknown_addresses:add(record.a);
								all_targets_ok = false;
							end
						end
					end
				end
				do
					local res = dns.lookup(idna.to_ascii(target_host), "AAAA");
					if res then
						for _, record in ipairs(res) do
							if external_addresses:contains(record.aaaa) then
								some_targets_ok = true;
								host_ok_v6 = true;
							elseif internal_addresses:contains(record.aaaa) then
								host_ok_v6 = true;
								some_targets_ok = true;
								print("    "..target_host.." AAAA record points to internal address, external connections might fail");
							else
								print("    "..target_host.." AAAA record points to unknown address "..record.aaaa);
								unknown_addresses:add(record.aaaa);
								all_targets_ok = false;
							end
						end
					end
				end

				if host_ok_v4 and not use_ipv4 then
					print("    Host "..target_host.." does seem to resolve to this server but IPv4 has been disabled");
					all_targets_ok = false;
				end

				if host_ok_v6 and not use_ipv6 then
					print("    Host "..target_host.." does seem to resolve to this server but IPv6 has been disabled");
					all_targets_ok = false;
				end

				local bad_protos = {}
				if use_ipv4 and not host_ok_v4 then
					table.insert(bad_protos, "IPv4");
				end
				if use_ipv6 and not host_ok_v6 then
					table.insert(bad_protos, "IPv6");
				end
				if #bad_protos > 0 then
					print("    Host "..target_host.." does not seem to resolve to this server ("..table.concat(bad_protos, "/")..")");
				end
				if host_ok_v6 and not v6_supported then
					print("    Host "..target_host.." has AAAA records, but your version of LuaSocket does not support IPv6.");
					print("      Please see https://prosody.im/doc/ipv6 for more information.");
				elseif host_ok_v6 and not use_ipv6 then
					print("    Host "..target_host.." has AAAA records, but IPv6 is disabled.");
					-- TODO Tell them to drop the AAAA records or enable IPv6?
					print("      Please see https://prosody.im/doc/ipv6 for more information.");
				end
			end
			if not all_targets_ok then
				print("    "..(some_targets_ok and "Only some" or "No").." targets for "..host.." appear to resolve to this server.");
				if is_component then
					print("    DNS records are necessary if you want users on other servers to access this component.");
				end
				problem_hosts:add(host);
			end
			print("");
		end
		if not problem_hosts:empty() then
			if not unknown_addresses:empty() then
				print("");
				print("Some of your DNS records point to unknown IP addresses. This may be expected if your server");
				print("is behind a NAT or proxy. The unrecognized addresses were:");
				print("");
				print("    Unrecognized: "..tostring(unknown_addresses));
				print("");
				print("The addresses we found on this system are:");
				print("");
				print("    Internal: "..tostring(internal_addresses));
				print("    External: "..tostring(external_addresses));
			end
			print("");
			print("For more information about DNS configuration please see https://prosody.im/doc/dns");
			print("");
			ok = false;
		end
	end
	if not what or what == "certs" then
		local cert_ok;
		print"Checking certificates..."
		local x509_verify_identity = require"util.x509".verify_identity;
		local create_context = require "core.certmanager".create_context;
		local ssl = dependencies.softreq"ssl";
		-- local datetime_parse = require"util.datetime".parse_x509;
		local load_cert = ssl and ssl.loadcertificate;
		-- or ssl.cert_from_pem
		if not ssl then
			print("LuaSec not available, can't perform certificate checks")
			if what == "certs" then cert_ok = false end
		elseif not load_cert then
			print("This version of LuaSec (" .. ssl._VERSION .. ") does not support certificate checking");
			cert_ok = false
		else
			for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
				print("Checking certificate for "..host);
				-- First, let's find out what certificate this host uses.
				local host_ssl_config = configmanager.rawget(host, "ssl")
					or configmanager.rawget(host:match("%.(.*)"), "ssl");
				local global_ssl_config = configmanager.rawget("*", "ssl");
				local ok, err, ssl_config = create_context(host, "server", host_ssl_config, global_ssl_config);
				if not ok then
					print("  Error: "..err);
					cert_ok = false
				elseif not ssl_config.certificate then
					print("  No 'certificate' found for "..host)
					cert_ok = false
				elseif not ssl_config.key then
					print("  No 'key' found for "..host)
					cert_ok = false
				else
					local key, err = io.open(ssl_config.key); -- Permissions check only
					if not key then
						print("    Could not open "..ssl_config.key..": "..err);
						cert_ok = false
					else
						key:close();
					end
					local cert_fh, err = io.open(ssl_config.certificate); -- Load the file.
					if not cert_fh then
						print("    Could not open "..ssl_config.certificate..": "..err);
						cert_ok = false
					else
						print("  Certificate: "..ssl_config.certificate)
						local cert = load_cert(cert_fh:read"*a"); cert_fh:close();
						if not cert:validat(os.time()) then
							print("    Certificate has expired.")
							cert_ok = false
						elseif not cert:validat(os.time() + 86400) then
							print("    Certificate expires within one day.")
							cert_ok = false
						elseif not cert:validat(os.time() + 86400*7) then
							print("    Certificate expires within one week.")
						elseif not cert:validat(os.time() + 86400*31) then
							print("    Certificate expires within one month.")
						end
						if configmanager.get(host, "component_module") == nil
							and not x509_verify_identity(host, "_xmpp-client", cert) then
							print("    Not valid for client connections to "..host..".")
							cert_ok = false
						end
						if (not (configmanager.get(host, "anonymous_login")
							or configmanager.get(host, "authentication") == "anonymous"))
							and not x509_verify_identity(host, "_xmpp-server", cert) then
							print("    Not valid for server-to-server connections to "..host..".")
							cert_ok = false
						end
					end
				end
			end
		end
		if cert_ok == false then
			print("")
			print("For more information about certificates please see https://prosody.im/doc/certificates");
			ok = false
		end
		print("")
	end
	-- intentionally not doing this by default
	if what == "connectivity" then
		local _, prosody_is_running = is_prosody_running();
		if configmanager.get("*", "pidfile") and not prosody_is_running then
			print("Prosody does not appear to be running, which is required for this test.");
			print("Start it and then try again.");
			return 1;
		end

		local checker = "observe.jabber.network";
		local probe_instance;
		local probe_modules = {
			["xmpp-client"] = "c2s_normal_auth";
			["xmpp-server"] = "s2s_normal";
			["xmpps-client"] = nil; -- TODO
			["xmpps-server"] = nil; -- TODO
		};
		local probe_settings = configmanager.get("*", "connectivity_probe");
		if type(probe_settings) == "string" then
			probe_instance = probe_settings;
		elseif type(probe_settings) == "table" and type(probe_settings.url) == "string" then
			probe_instance = probe_settings.url;
			if type(probe_settings.modules) == "table" then
				probe_modules = probe_settings.modules;
			end
		elseif probe_settings ~= nil then
			print("The 'connectivity_probe' setting not understood.");
			print("Expected an URL or a table with 'url' and 'modules' fields");
			print("See https://prosody.im/doc/prosodyctl#check for more information."); -- FIXME
			return 1;
		end

		local check_api;
		if probe_instance then
			local parsed_url = socket_url.parse(probe_instance);
			if not parsed_url then
				print(("'connectivity_probe' is not a valid URL: %q"):format(probe_instance));
				print("Set it to the URL of an XMPP Blackbox Exporter instance and try again");
				return 1;
			end
			checker = parsed_url.host;

			function check_api(protocol, host)
				local target = socket_url.build({scheme="xmpp",path=host});
				local probe_module = probe_modules[protocol];
				if not probe_module then
					return nil, "Checking protocol '"..protocol.."' is currently unsupported";
				end
				return check_probe(probe_instance, probe_module, target);
			end
		else
			check_api = check_ojn;
		end

		for host in it.filter(skip_bare_jid_hosts, enabled_hosts()) do
			local modules, component_module = modulemanager.get_modules_for_host(host);
			if component_module then
				modules:add(component_module)
			end

			print("Checking external connectivity for "..host.." via "..checker)
			local function check_connectivity(protocol)
				local success, err = check_api(protocol, host);
				if not success and err ~= nil then
					print(("  %s: Failed to request check at API: %s"):format(protocol, err))
				elseif success then
					print(("  %s: Works"):format(protocol))
				else
					print(("  %s: Check service failed to establish (secure) connection"):format(protocol))
					ok = false
				end
			end

			if modules:contains("c2s") then
				check_connectivity("xmpp-client")
				if configmanager.get("*", "c2s_direct_tls_ports") then
					check_connectivity("xmpps-client");
				end
			end

			if modules:contains("s2s") then
				check_connectivity("xmpp-server")
				if configmanager.get("*", "s2s_direct_tls_ports") then
					check_connectivity("xmpps-server");
				end
			end

			print()
		end
		print("Note: The connectivity check only checks the reachability of the domain.")
		print("Note: It does not ensure that the check actually reaches this specific prosody instance.")
	end

	if not what or what == "turn" then
		local turn_enabled_hosts = {};
		local turn_services = {};

		for host in enabled_hosts() do
			local has_external_turn = modulemanager.get_modules_for_host(host):contains("turn_external");
			if has_external_turn then
				table.insert(turn_enabled_hosts, host);
				local turn_host = configmanager.get(host, "turn_external_host") or host;
				local turn_port = configmanager.get(host, "turn_external_port") or 3478;
				local turn_secret = configmanager.get(host, "turn_external_secret");
				if not turn_secret then
					print("Error: Your configuration is missing a turn_external_secret for "..host);
					print("Error: TURN will not be advertised for this host.");
					ok = false;
				else
					local turn_id = ("%s:%d"):format(turn_host, turn_port);
					if turn_services[turn_id] and turn_services[turn_id].secret ~= turn_secret then
						print("Error: Your configuration contains multiple differing secrets");
						print("       for the TURN service at "..turn_id.." - we will only test one.");
					elseif not turn_services[turn_id] then
						turn_services[turn_id] = {
							host = turn_host;
							port = turn_port;
							secret = turn_secret;
						};
					end
				end
			end
		end

		if what == "turn" then
			local count = it.count(pairs(turn_services));
			if count == 0 then
				print("Error: Unable to find any TURN services configured. Enable mod_turn_external!");
				ok = false;
			else
				print("Identified "..tostring(count).." TURN services.");
				print("");
			end
		end

		for turn_id, turn_service in pairs(turn_services) do
			print("Testing TURN service "..turn_id.."...");

			local result = check_turn_service(turn_service, opts.ping);
			if #result.warnings > 0 then
				print(("%d warnings:\n"):format(#result.warnings));
				print("    "..table.concat(result.warnings, "\n    "));
				print("");
			end

			if opts.verbose then
				if result.external_ip then
					print(("External IP: %s"):format(result.external_ip.address));
				end
				if result.relayed_addresses then
					for i, relayed_address in ipairs(result.relayed_addresses) do
						print(("Relayed address %d: %s:%d"):format(i, relayed_address.address, relayed_address.port));
					end
				end
				if result.external_ip_pong then
					print(("TURN external address: %s:%d"):format(result.external_ip_pong.address, result.external_ip_pong.port));
				end
			end

			if result.error then
				print("Error: "..result.error.."\n");
				ok = false;
			else
				print("Success!\n");
			end
		end
	end

	if not ok then
		print("Problems found, see above.");
	else
		print("All checks passed, congratulations!");
	end
	return ok and 0 or 2;
end

return {
	check = check;
};
