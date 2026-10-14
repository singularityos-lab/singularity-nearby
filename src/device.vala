namespace Singularity.Nearby {

    public enum PairState {
        NONE,
        REQUESTED,
        INCOMING,
        PAIRED;

        public string to_id() {
            switch (this) {
                case REQUESTED: return "requested";
                case INCOMING: return "incoming";
                case PAIRED: return "paired";
                default: return "none";
            }
        }
    }

    public class SmsMessage : Object {
        public int64 id { get; set; }
        public int64 thread { get; set; }
        public string body { get; set; default = ""; }
        public string address { get; set; default = ""; }
        public int64 date { get; set; }
        public int kind { get; set; default = 1; }
        public bool read { get; set; default = true; }

        public HashTable<string, Variant> to_dict() {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["id"] = id;
            d["thread"] = thread;
            d["body"] = body;
            d["address"] = address;
            d["date"] = date;
            d["outgoing"] = kind == 2;
            d["read"] = read;
            return d;
        }
    }

    public class MediaPlayer : Object {
        public string name { get; construct; }
        public string title { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public string album { get; set; default = ""; }
        public bool playing { get; set; default = false; }
        public bool can_play { get; set; default = true; }
        public bool can_pause { get; set; default = true; }
        public bool can_next { get; set; default = true; }
        public bool can_previous { get; set; default = true; }
        public int64 length { get; set; default = 0; }
        public int64 position { get; set; default = 0; }
        public int volume { get; set; default = 100; }

        public MediaPlayer(string name) {
            Object(name: name);
        }

        public HashTable<string, Variant> to_dict() {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["name"] = name;
            d["title"] = title;
            d["artist"] = artist;
            d["album"] = album;
            d["playing"] = playing;
            d["can-play"] = can_play;
            d["can-pause"] = can_pause;
            d["can-next"] = can_next;
            d["can-previous"] = can_previous;
            d["length"] = length;
            d["position"] = position;
            d["volume"] = volume;
            return d;
        }
    }

    public class PhoneNotification : Object {
        public string key { get; construct; }
        public uint32 local_id { get; set; default = 0; }
        public string app_name { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string text { get; set; default = ""; }
        public string reply_id { get; set; default = ""; }
        public bool clearable { get; set; default = true; }
        public string[] actions { get; set; default = {}; }
        public string icon_path { get; set; default = ""; }
        public bool closing { get; set; default = false; }
        public int64 time { get; set; default = 0; }

        public PhoneNotification(string key) {
            Object(key: key);
        }

        public HashTable<string, Variant> to_dict() {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["key"] = key;
            d["app"] = app_name;
            d["title"] = title;
            d["text"] = text;
            d["icon"] = icon_path;
            d["can-reply"] = reply_id != "";
            d["clearable"] = clearable;
            d["actions"] = actions;
            d["time"] = time;
            return d;
        }
    }

    public class Device : Object {
        public const string[] PLUGINS = { "share", "clipboard", "notifications", "battery", "findmyphone", "sms", "mpris", "runcommand", "ping" };
        public const string[] PEER_PLUGINS = { "share", "ping" };

        public string id { get; construct; }
        public string name { get; set; default = ""; }
        public string device_type { get; set; default = "phone"; }
        public int protocol_version { get; set; default = Packet.PROTOCOL_VERSION; }
        public string[] incoming { get; set; default = {}; }
        public string[] outgoing { get; set; default = {}; }
        public Link? link { get; set; default = null; }
        public DeviceRecord? record { get; set; default = null; }
        public PairState pair_state { get; set; default = PairState.NONE; }
        public int64 pair_timestamp { get; set; default = 0; }
        public string verification { get; set; default = ""; }
        public uint pair_timeout { get; set; default = 0; }
        public uint32 pair_notification { get; set; default = 0; }
        public int battery { get; set; default = -1; }
        public bool charging { get; set; default = false; }
        public string address { get; set; default = ""; }
        public int64 remote_clipboard_time { get; set; default = 0; }
        public string[] remote_commands { get; set; default = {}; }

        public Gee.HashMap<string, Gee.ArrayList<SmsMessage>> threads { get; default = new Gee.HashMap<string, Gee.ArrayList<SmsMessage>>(); }
        public Gee.HashMap<string, MediaPlayer> players { get; default = new Gee.HashMap<string, MediaPlayer>(); }
        public Gee.HashMap<string, PhoneNotification> notifications { get; default = new Gee.HashMap<string, PhoneNotification>(); }

        public Device(string id) {
            Object(id: id);
        }

        public bool reachable {
            get { return link != null && link.open; }
        }

        public bool paired {
            get { return pair_state == PairState.PAIRED; }
        }

        public string certificate_pem {
            owned get {
                if (link != null) return link.peer_certificate_pem;
                return record != null ? record.certificate : "";
            }
        }

        public static string icon_for(string type) {
            switch (type) {
                case "phone":
                case "smartphone": return "phone-symbolic";
                case "tablet": return "phone-symbolic";
                case "tv": return "tv-symbolic";
                default: return "computer-symbolic";
            }
        }

        public bool is_computer {
            get { return device_type != "phone" && device_type != "tablet"; }
        }

        private bool opt_in(string plugin) {
            return plugin == "runcommand" || (is_computer && !(plugin in PEER_PLUGINS));
        }

        public bool plugin_enabled(string plugin, SystemConfig system) {
            if (!paired || record == null) return false;
            if (plugin == "runcommand") return system.allow_run_commands && plugin in record.enabled_plugins;
            if (opt_in(plugin)) return plugin in record.enabled_plugins;
            return !(plugin in record.disabled_plugins);
        }

        public void set_plugin(string plugin, bool on) {
            if (record == null) return;
            string[] disabled = {};
            foreach (string p in record.disabled_plugins) if (p != plugin) disabled += p;
            string[] enabled = {};
            foreach (string p in record.enabled_plugins) if (p != plugin) enabled += p;
            if (opt_in(plugin)) {
                if (on) enabled += plugin;
            } else if (!on) {
                disabled += plugin;
            }
            record.disabled_plugins = disabled;
            record.enabled_plugins = enabled;
        }

        public void apply_identity(Packet identity) {
            name = Packet.filter_name(identity.get_string("deviceName", name));
            string t = identity.get_string("deviceType", device_type);
            device_type = t == "smartphone" ? "phone" : t;
            protocol_version = (int) identity.get_int("protocolVersion", protocol_version);
            incoming = identity.get_strv("incomingCapabilities");
            outgoing = identity.get_strv("outgoingCapabilities");
        }

        public bool accepts(string packet_type) {
            return incoming.length == 0 || packet_type in incoming;
        }

        public void store_message(SmsMessage m) {
            var list = threads[m.thread.to_string()];
            if (list == null) {
                list = new Gee.ArrayList<SmsMessage>();
                threads[m.thread.to_string()] = list;
            }
            for (int i = 0; i < list.size; i++) {
                if (list[i].id == m.id) {
                    list[i] = m;
                    return;
                }
            }
            list.add(m);
            list.sort((a, b) => a.date < b.date ? -1 : (a.date > b.date ? 1 : 0));
        }

        public HashTable<string, Variant> to_dict(SystemConfig system) {
            var d = new HashTable<string, Variant>(str_hash, str_equal);
            d["id"] = id;
            d["name"] = name;
            d["type"] = device_type;
            d["icon"] = icon_for(device_type);
            d["reachable"] = reachable;
            d["paired"] = paired;
            d["pair-state"] = pair_state.to_id();
            d["verification"] = verification;
            d["battery"] = battery;
            d["charging"] = charging;
            d["address"] = address;
            d["always-allow-files"] = record != null && record.always_allow_files;
            string[] enabled = {};
            foreach (string p in PLUGINS) if (plugin_enabled(p, system)) enabled += p;
            d["plugins"] = enabled;
            d["supports-sms"] = incoming.length == 0 || Packet.SMS_REQUEST in incoming;
            d["supports-find"] = incoming.length == 0 || Packet.FINDMYPHONE in incoming;
            d["supports-media"] = players.size > 0;
            d["has-conversations"] = threads.size > 0;
            d["notification-count"] = notifications.size;
            return d;
        }
    }
}
