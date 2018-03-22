local log = require 'log'
local con = require 'console'
local fiber = require 'fiber'
local json = require 'json'
local yaml = require 'yaml'
json.cfg{ encode_invalid_as_nil = true }
-- yaml.cfg{ encode_invalid_as_nil = true }

local readonly_mt = {
	__index = function(_,k) return rawget(_,k) end;
	__newindex = function(_,k)
		error("Modification of readonly key "..tostring(k),2)
	end;
	__serialize = function(_)
		local t = {}
		for k,v in pairs(_) do
			t[k]=v
		end
		return t
	end;
}

local function flatten (t,prefix,result)
	prefix = prefix or ''
	local protect = not result
	result = result or {}
	for k,v in pairs(t) do
		if type(v) == 'table' then
			flatten(v, prefix..k..'.',result)
		end
		result[prefix..k] = v
	end
	if protect then
		return setmetatable(result,readonly_mt)
	end
	return result
end

local function get_opt()
	local take = false
	local key
	for k,v in ipairs(arg) do
		if take then
			if key == 'config' or key == 'c' then
				return v
			end
		else
			if string.sub( v, 1, 2) == "--" then
				local x = string.find( v, "=", 1, true )
				if x then
					key = string.sub( v, 3, x-1 )
					-- print("have key=")
					if key == 'config' then
						return string.sub( v, x+1 )
					end
				else
					-- print("have key, turn take")
					key = string.sub( v, 3 )
					take = true
				end
			elseif string.sub( v, 1, 1 ) == "-" then
				if string.len(v) == 2 then
					key = string.sub(v,2,2)
					take = true
				else
					key = string.sub(v,2,2)
					if key == 'c' then
						return string.sub( v, 3 )
					end
				end
			end
		end
	end
end

local function deep_merge(dst,src)
	-- TODO: think of cyclic
	if not src or not dst then error("Call to deepmerge with bad args",2) end
	for k,v in pairs(src) do
		if type(v) == 'table' then
			if not dst[k] then dst[k] = {} end
			deep_merge(dst[k],src[k])
		else
			dst[k] = src[k]
		end
	end
end

local function deep_copy(src)
	local t = {}
	deep_merge(t, src)
	return t
end

local function etcd_load( M, etcd_conf, local_cfg )

	local etcd = require 'config.etcd' (etcd_conf)
	M.etcd = etcd

	etcd:discovery()

	local instance_name = assert(etcd_conf.instance_name,"etcd.instance_name is required")
	local prefix = assert(etcd_conf.prefix,"etcd.prefix is required")

	local cfg = etcd:list(prefix .. "/common")
	assert(cfg.box,"no box config in etcd common tree")

	-- print(yaml.encode(cfg))

	local inst_cfg = etcd:list(prefix .. "/instances")
	for k,v in pairs(inst_cfg) do
		v.box.read_only = v.box.read_only == 'true'
	end
	local my_cfg = inst_cfg[instance_name]
	assert(my_cfg,"Instance name "..instance_name.." is not known to etcd")
	deep_merge(cfg, my_cfg)

	local members = {}
	for k,v in pairs(inst_cfg) do
		if v.cluster == cfg.cluster then -- and k ~= instance_name then
			table.insert(members,v)
		end
	end

	if my_cfg.cluster then
		local cls_cfg = etcd:list(prefix.."/clusters/"..my_cfg.cluster)
		assert(cls_cfg.replicaset_uuid,"Need cluster uuid")
		cfg.box.replicaset_uuid = cls_cfg.replicaset_uuid
	end


	-- now, put local cfg over calculated
	deep_merge(cfg,local_cfg)

	-- print("members: ",yaml.encode(members))
	if my_cfg.cluster then
		--if cfg.box.read_only then
			cfg.box.replication = {}
			for _,member in pairs(members) do
				--if not member.box.read_only then
					table.insert(cfg.box.replication, member.box.listen)
				--else
				--	print("Skip ro member",member.box.listen)
				--end
			end
			table.sort(cfg.box.replication, function(a,b)
				local ha,pa = a:match('^([^:]+):(.+)')
				local hb,pb = a:match('^([^:]+):(.+)')
				if pa and pb then
					if pa < pb then return true end
					if ha < hb then return true end
				end
				return a < b
			end)
			print("Start instance ",cfg.box.listen," with replication:",table.concat(cfg.box.replication,", "))
		--end
	end
	-- print(yaml.encode(cfg))

	return cfg
end

local M
--if rawget(_G,'config') then
--	M = rawget(_G,'config')
--else
	M = setmetatable({
		console = {};
		get = function(self,k,def)
			if self ~= M then
				def = k
				k = self
			end
			if M._flat[k] ~= nil then
				return M._flat[k]
			else
				return def
			end
		end
	},{
		__call = function(M, args)
			-- args MUST belong to us, because of modification
			local file
			if type(args) == 'string' then
				file = args
				args = {}
			elseif type(args) == 'table' then
				args = deep_copy(args)
				file = args.file
			else
				args = {}
			end
			-- print("config", "loading ",file, json.encode(args))
			if not file then
				file = get_opt()
				-- todo: maybe etcd?
				if not file then error("Neither config call option given not -c|--config option passed",2) end
			end
			print(string.format("Loading config 1 %s %s", file, json.encode(args)))
			local f,e = loadfile(file)
			if not f then error(e,2) end
			-- local cfg = setmetatable({},{__index = _G })
			local cfg = setmetatable({},{ __index = setmetatable(args,{ __index = _G }) })
			-- local cfg = setmetatable({},{__index = { print = _G.print, loadstring = _G.loadstring }})
			setfenv(f,cfg)
			f()
			setmetatable(cfg,nil)
			setmetatable(args,nil)

			-- subject to change, just a PoC
			local etcd_conf = args.etcd or cfg.etcd
			if etcd_conf then
				cfg = etcd_load(M, etcd_conf, cfg)
			end

			if not cfg.box then
				error("No box.* config given", 2)
			end

			-- if not cfg.box.custom_proc_title and args.instance_name then
			-- 	cfg.box.custom_proc_title = args.instance_name
			-- end

			-- latest modifications and fixups
			if args.on_load then
				args.on_load(M,cfg)
			end

			M._flat = flatten(cfg)

			if args.mkdir then
				local fio = require 'fio'
				for _,key in pairs({"work_dir", "wal_dir", "snap_dir", "memtx_dir", "vinyl_dir"}) do
					local v = cfg.box[key]
					if v and not fio.path.exists(v) then
						local r,e = fio.mktree(v)
						if not r then error(string.format("Failed to create path '%s' for %s: %s",v,key,e),2) end
					end
				end
				local v = cfg.box.pid_file
				if v then
					v = fio.dirname(v);
					if v and not fio.path.exists(v) then
						local r,e = fio.mktree(v)
						if not r then error(string.format("Failed to create path '%s' for pid_file: %s",v,e),2) end
					end
				end
			end

			-- print(string.format("Starting app: %s", yaml.encode(cfg.box)))
			if args.boxcfg then
				args.boxcfg( cfg.box )
			else
				-- local replication = cfg.box.replication_source or cfg.box.replication
				-- cfg.box.replication = nil
				-- cfg.box.replication_source = nil

				if type(box.cfg) == 'function' then
					box.cfg( cfg.box )
				else
					cfg.box.pid_file = nil
					cfg.box.background = nil
					--print("Hide bad options")
					--require'log'.info("Hide bad options")
					box.cfg( cfg.box )
				end

				-- if replication then
				-- 	box.cfg{ replication = replication }
				-- end
			end
			-- print(string.format("Box configured"))

			return M
		end
	})
	rawset(_G,'config',M)
--end

return M
