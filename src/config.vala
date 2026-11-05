namespace Singularity.Nearby {

    public class SystemConfig : Object {
        public bool enabled { get; set; default = true; }
        public bool broadcast { get; set; default = true; }
        public bool mdns { get; set; default = true; }
        public int udp_port { get; set; default = 1716; }
        public int tcp_port_min { get; set; default = 1716; }
        public int tcp_port_max { get; set; default = 1764; }
        public int transfer_port_min { get; set; default = 1739; }
        public int transfer_port_max { get; set; default = 1764; }
        public string device_type { get; set; default = ""; }
        public bool allow_run_commands { get; set; default = true; }
        public string[] extra_addresses { get; set; default = {}; }
        public string relay { get; set; default = ""; }
        public string? source { get; private set; default = null; }

        public static string[] search_paths() {
            string[] paths = {};
            string? env = Environment.get_variable("SINGULARITY_NEARBY_CONF");
            if (env != null && env != "") paths += env;
            foreach (string dir in Environment.get_system_config_dirs()) paths += Path.build_filename(dir, "singularity", "nearby.conf");
            paths += Path.build_filename(BuildConfig.SYSCONFDIR, "singularity", "nearby.conf");
            return paths;
        }

        public static SystemConfig load() {
            var config = new SystemConfig();
            foreach (string path in search_paths()) {
                if (!FileUtils.test(path, FileTest.EXISTS)) continue;
                var kf = new KeyFile();
                try {
                    kf.load_from_file(path, KeyFileFlags.NONE);
                } catch (Error e) {
                    warning("%s: %s", path, e.message);
                    continue;
                }
                config.source = path;
                config.read(kf);
                break;
            }
            return config;
        }

        private void read(KeyFile kf) {
            const string G = "Nearby";
            try {
                if (kf.has_key(G, "Enabled")) enabled = kf.get_boolean(G, "Enabled");
                if (kf.has_key(G, "Discovery")) {
                    string[] methods = kf.get_string_list(G, "Discovery");
                    broadcast = "broadcast" in methods;
                    mdns = "mdns" in methods;
                }
                if (kf.has_key(G, "UdpPort")) udp_port = kf.get_integer(G, "UdpPort");
                if (kf.has_key(G, "TcpPorts")) {
                    int[] r = kf.get_integer_list(G, "TcpPorts");
                    if (r.length == 2) {
                        tcp_port_min = r[0];
                        tcp_port_max = r[1];
                    }
                }
                if (kf.has_key(G, "TransferPorts")) {
                    int[] r = kf.get_integer_list(G, "TransferPorts");
                    if (r.length == 2) {
                        transfer_port_min = r[0];
                        transfer_port_max = r[1];
                    }
                }
                if (kf.has_key(G, "DeviceType")) device_type = kf.get_string(G, "DeviceType");
                if (kf.has_key(G, "AllowRunCommands")) allow_run_commands = kf.get_boolean(G, "AllowRunCommands");
                if (kf.has_key(G, "Addresses")) extra_addresses = kf.get_string_list(G, "Addresses");
                if (kf.has_key(G, "Relay")) relay = kf.get_string(G, "Relay").strip();
            } catch (Error e) {
                warning("nearby.conf: %s", e.message);
            }
        }

        public string resolved_device_type() {
            if (device_type == "desktop" || device_type == "laptop" || device_type == "tablet" || device_type == "phone" || device_type == "tv") return device_type;
            string chassis;
            try {
                if (FileUtils.get_contents("/sys/class/dmi/id/chassis_type", out chassis)) {
                    int t = int.parse(chassis.strip());
                    if (t == 8 || t == 9 || t == 10 || t == 14 || t == 31 || t == 32) return "laptop";
                    if (t == 30) return "tablet";
                }
            } catch (FileError e) {
            }
            return "desktop";
        }
    }

    public class DeviceRecord : Object {
        public string id { get; construct; }
        public string name { get; set; default = ""; }
        public string device_type { get; set; default = "phone"; }
        public string certificate { get; set; default = ""; }
        public int protocol_version { get; set; default = Packet.PROTOCOL_VERSION; }
        public string[] disabled_plugins { get; set; default = {}; }
        public string[] enabled_plugins { get; set; default = {}; }
        public bool always_allow_files { get; set; default = false; }
        public string last_address { get; set; default = ""; }
        public string room_secret { get; set; default = ""; }
        public string push_token { get; set; default = ""; }

        public DeviceRecord(string id) {
            Object(id: id);
        }
    }

    public class UserConfig : Object {
        public string dir { get; construct; }
        public string device_id { get; private set; }
        public string device_name { get; set; }
        public bool discoverable { get; set; default = true; }
        public string receive_folder { get; set; default = ""; }
        public string certificate_pem { get; private set; }
        public string private_key_pem { get; private set; }
        public Gee.HashMap<string, DeviceRecord> trusted { get; private set; default = new Gee.HashMap<string, DeviceRecord>(); }
        public Gee.ArrayList<RunCommand> commands { get; private set; default = new Gee.ArrayList<RunCommand>(); }

        public UserConfig(string dir) {
            Object(dir: dir);
        }

        public static string default_dir() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "nearby");
        }

        public void load() throws Error {
            DirUtils.create_with_parents(dir, 0700);
            var kf = new KeyFile();
            string path = Path.build_filename(dir, "nearby.ini");
            if (FileUtils.test(path, FileTest.EXISTS)) kf.load_from_file(path, KeyFileFlags.NONE);
            device_id = has(kf, "Identity", "Id") ? kf.get_string("Identity", "Id") : "";
            if (!Packet.valid_device_id(device_id)) device_id = Uuid.string_random().replace("-", "_");
            device_name = has(kf, "Identity", "Name") ? kf.get_string("Identity", "Name") : default_name();
            if (has(kf, "Settings", "Discoverable")) discoverable = kf.get_boolean("Settings", "Discoverable");
            receive_folder = has(kf, "Settings", "ReceiveFolder") ? kf.get_string("Settings", "ReceiveFolder") : default_receive_folder();
            foreach (string group in kf.get_groups()) {
                if (!group.has_prefix("Device ")) continue;
                string id = group.substring(7);
                if (!Packet.valid_device_id(id)) continue;
                var r = new DeviceRecord(id);
                if (kf.has_key(group, "Name")) r.name = kf.get_string(group, "Name");
                if (kf.has_key(group, "Type")) r.device_type = kf.get_string(group, "Type");
                if (kf.has_key(group, "Protocol")) r.protocol_version = kf.get_integer(group, "Protocol");
                if (kf.has_key(group, "DisabledPlugins")) r.disabled_plugins = kf.get_string_list(group, "DisabledPlugins");
                if (kf.has_key(group, "EnabledPlugins")) r.enabled_plugins = kf.get_string_list(group, "EnabledPlugins");
                if (kf.has_key(group, "AlwaysAllowFiles")) r.always_allow_files = kf.get_boolean(group, "AlwaysAllowFiles");
                if (kf.has_key(group, "Address")) r.last_address = kf.get_string(group, "Address");
                if (kf.has_key(group, "RoomSecret")) r.room_secret = kf.get_string(group, "RoomSecret");
                if (kf.has_key(group, "PushToken")) r.push_token = kf.get_string(group, "PushToken");
                string cert_path = Path.build_filename(dir, "devices", id + ".pem");
                string pem;
                if (FileUtils.get_contents(cert_path, out pem)) r.certificate = pem;
                if (r.certificate != "") trusted[id] = r;
            }
            load_commands();
            load_identity();
            save();
        }

        private static bool has(KeyFile kf, string group, string key) {
            try {
                return kf.has_group(group) && kf.has_key(group, key);
            } catch (KeyFileError e) {
                return false;
            }
        }

        private void load_identity() throws Error {
            string cert_path = Path.build_filename(dir, "certificate.pem");
            string key_path = Path.build_filename(dir, "private-key.pem");
            string cert = "", key = "";
            bool have = FileUtils.test(cert_path, FileTest.EXISTS) && FileUtils.test(key_path, FileTest.EXISTS);
            if (have) {
                FileUtils.get_contents(cert_path, out cert);
                FileUtils.get_contents(key_path, out key);
                try {
                    if (NearbyCerts.common_name(cert) != device_id) have = false;
                } catch (Error e) {
                    have = false;
                }
            }
            if (!have) {
                NearbyCerts.generate(device_id, out cert, out key);
                FileUtils.set_contents_full(key_path, key, -1, FileSetContentsFlags.CONSISTENT, 0600);
                FileUtils.set_contents_full(cert_path, cert, -1, FileSetContentsFlags.CONSISTENT, 0600);
            }
            certificate_pem = cert;
            private_key_pem = key;
        }

        private void load_commands() {
            commands.clear();
            string data;
            try {
                if (!FileUtils.get_contents(Path.build_filename(dir, "commands.json"), out data)) return;
                var parser = new Json.Parser();
                parser.load_from_data(data);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                root.get_object().foreach_member((o, key, node) => {
                    if (node.get_node_type() != Json.NodeType.OBJECT) return;
                    var obj = node.get_object();
                    commands.add(new RunCommand(key, obj.get_string_member_with_default("name", key), obj.get_string_member_with_default("command", "")));
                });
            } catch (Error e) {
            }
        }

        public string commands_json() {
            var obj = new Json.Object();
            foreach (var c in commands) {
                var entry = new Json.Object();
                entry.set_string_member("name", c.name);
                entry.set_string_member("command", c.command);
                obj.set_object_member(c.key, entry);
            }
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(obj);
            var gen = new Json.Generator();
            gen.set_root(node);
            return gen.to_data(null);
        }

        public void save() throws Error {
            var kf = new KeyFile();
            kf.set_string("Identity", "Id", device_id);
            kf.set_string("Identity", "Name", device_name);
            kf.set_boolean("Settings", "Discoverable", discoverable);
            kf.set_string("Settings", "ReceiveFolder", receive_folder);
            string devices_dir = Path.build_filename(dir, "devices");
            DirUtils.create_with_parents(devices_dir, 0700);
            foreach (var r in trusted.values) {
                string group = "Device " + r.id;
                kf.set_string(group, "Name", r.name);
                kf.set_string(group, "Type", r.device_type);
                kf.set_integer(group, "Protocol", r.protocol_version);
                kf.set_string_list(group, "DisabledPlugins", r.disabled_plugins);
                kf.set_string_list(group, "EnabledPlugins", r.enabled_plugins);
                kf.set_boolean(group, "AlwaysAllowFiles", r.always_allow_files);
                kf.set_string(group, "Address", r.last_address);
                if (r.room_secret != "") kf.set_string(group, "RoomSecret", r.room_secret);
                if (r.push_token != "") kf.set_string(group, "PushToken", r.push_token);
                FileUtils.set_contents_full(Path.build_filename(devices_dir, r.id + ".pem"), r.certificate, -1, FileSetContentsFlags.CONSISTENT, 0600);
            }
            FileUtils.set_contents_full(Path.build_filename(dir, "nearby.ini"), kf.to_data(), -1, FileSetContentsFlags.CONSISTENT, 0600);
            FileUtils.set_contents_full(Path.build_filename(dir, "commands.json"), commands_json(), -1, FileSetContentsFlags.CONSISTENT, 0600);
        }

        public void forget(string id) {
            trusted.unset(id);
            FileUtils.remove(Path.build_filename(dir, "devices", id + ".pem"));
        }

        public static string default_name() {
            string? name = Environment.get_host_name();
            name = Packet.filter_name(name);
            return name != "" ? name : "Singularity";
        }

        public static string default_receive_folder() {
            string? dl = Environment.get_user_special_dir(UserDirectory.DOWNLOAD);
            if (dl != null && dl != Environment.get_home_dir()) return dl;
            return Path.build_filename(Environment.get_home_dir(), "Downloads");
        }
    }

    public class RunCommand : Object {
        public string key { get; construct; }
        public string name { get; set; }
        public string command { get; set; }

        public RunCommand(string key, string name, string command) {
            Object(key: key, name: name, command: command);
        }
    }
}
