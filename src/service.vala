namespace Singularity.Nearby {

    [DBus (name = "dev.sinty.Nearby1.Error")]
    public errordomain NearbyError {
        NOT_FOUND,
        NOT_PAIRED,
        NOT_REACHABLE,
        DISABLED,
        FAILED
    }

    public class PendingAnswer {
        public Answer answer;
    }

    [DBus (name = "dev.sinty.Nearby1")]
    public class Service : Object {
        public const int PAIR_TIMEOUT = 30;
        public const int IDLE_LINK = 120;
        public const int64 ALLOWED_CLOCK_SKEW = 1800;
        public const int MAX_UNPAIRED = 42;
        private const string[] OPENABLE_SCHEMES = { "http", "https", "mailto", "tel", "geo", "sms" };

        private UserConfig config;
        private SystemConfig system;
        private LanProvider lan;
        private Desktop desktop;
        private LocalMedia media;
        private Obex obex;
        private Bytes own_public_key;
        private Gee.HashMap<string, Device> devices = new Gee.HashMap<string, Device>();
        private Gee.HashMap<string, IncomingBatch> batches = new Gee.HashMap<string, IncomingBatch>();
        private Gee.ArrayList<string> added_addresses = new Gee.ArrayList<string>();
        private string last_clipboard = "";
        private int64 clipboard_time = 0;
        private ReceivedHistory history;
        private Gee.ArrayList<TransferInfo> transfers = new Gee.ArrayList<TransferInfo>();

        [DBus (visible = false)]
        public Collab collab { get; private set; }

        public signal void devices_changed();
        public signal void device_changed(string id);
        public signal void pair_requested(string id, string name, string code);
        public signal void clipboard_received(string text, string device_id);
        public signal void transfer_requested(string batch_id, string device_id, string summary, int64 size);
        public signal void transfer_progress(string transfer_id, int64 done, int64 total);
        public signal void transfer_finished(string transfer_id, bool ok, string detail);
        public signal void conversations_changed(string device_id);
        public signal void media_changed(string device_id);
        public signal void notifications_changed(string device_id);
        public signal void transfer_started(string transfer_id, string device_id, string name, int64 size, bool incoming);
        public signal void received_files_changed();

        public string id { owned get { return config.device_id; } }
        public string name {
            owned get { return config.device_name; }
            set {
                string n = Packet.filter_name(value);
                if (n == "" || n == config.device_name) return;
                config.device_name = n;
                save();
                if (lan.mdns != null) lan.mdns.device_name = n;
                refresh_discovery();
            }
        }
        public bool discoverable {
            get { return config.discoverable; }
            set {
                if (value == config.discoverable) return;
                config.discoverable = value;
                save();
                lan.set_discoverable(value);
                if (value) refresh_discovery();
            }
        }
        public string receive_folder {
            owned get { return config.receive_folder; }
            set {
                if (value == "" || value == config.receive_folder) return;
                config.receive_folder = value;
                obex.receive_folder = value;
                save();
            }
        }
        public bool bluetooth_available { get { return obex.available; } }
        public int port { get { return lan.tcp_port; } }
        public bool run_commands_allowed { get { return system.allow_run_commands; } }

        [DBus (visible = false)]
        public Service(DBusConnection bus, UserConfig config, SystemConfig system) throws Error {
            this.config = config;
            this.system = system;
            desktop = new Desktop(bus);
            media = new LocalMedia(bus);
            media.changed.connect(on_local_media_changed);
            obex = new Obex(bus);
            obex.receive_folder = config.receive_folder;
            obex.question_handler = ask_bluetooth;
            obex.received.connect((path, device) => {
                history.add(path, "", device != "" ? device : _("Bluetooth"));
                announce_received(path, device != "" ? device : _("Bluetooth"));
            });
            obex.progress.connect((i, d, t) => transfer_progress(i, d, t));
            obex.finished.connect((i, ok, msg) => transfer_finished(i, ok, msg));
            obex.notify["available"].connect(() => notify_property("bluetooth-available"));
            own_public_key = NearbyCerts.public_key_der(config.certificate_pem);
            history = new ReceivedHistory(Environment.get_variable("SINGULARITY_NEARBY_HISTORY") ?? ReceivedHistory.default_file());
            history.load();
            history.changed.connect(() => received_files_changed());
            transfer_progress.connect(on_transfer_progress);
            transfer_finished.connect(on_transfer_finished);

            foreach (var r in config.trusted.values) {
                var d = new Device(r.id);
                d.record = r;
                d.name = r.name;
                d.device_type = r.device_type;
                d.protocol_version = r.protocol_version;
                d.pair_state = PairState.PAIRED;
                d.address = r.last_address;
                devices[r.id] = d;
            }

            lan = new LanProvider(config, system, build_identity, (id) => {
                var r = config.trusted[id];
                return r != null ? r.certificate : null;
            }, (id) => {
                if (config.trusted.has_key(id)) return true;
                if (!config.discoverable) return false;
                int unpaired = 0;
                foreach (var d in devices.values) if (!d.paired && d.reachable) unpaired++;
                return unpaired < MAX_UNPAIRED;
            });
            lan.link_ready.connect(on_link);
            collab = new Collab(this, config.dir);
        }

        [DBus (visible = false)]
        public Gee.Collection<Device> collab_devices() {
            return devices.values;
        }

        [DBus (visible = false)]
        public Device? collab_device(string id) {
            return devices[id];
        }

        [DBus (visible = false)]
        public void collab_send(Device d, Packet p) {
            send(d, p);
        }

        [DBus (visible = false)]
        public void collab_capabilities_changed() {
            refresh_discovery();
        }

        [DBus (visible = false)]
        public void collab_notify(string summary, string body) {
            desktop.send_notification.begin(_("Nearby"), Desktop.APP_ID, summary, body, {});
        }

        [DBus (visible = false)]
        public void collab_ask(string summary, string body, owned NotificationAction answer) {
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            hints["urgency"] = new Variant.byte(2);
            desktop.send_notification.begin(_("Nearby"), Desktop.APP_ID, summary, body,
                { "accept", _("Accept"), "decline", _("Decline") }, hints, 0, (owned) answer);
        }

        [DBus (visible = false)]
        public void start() throws Error {
            lan.start();
            lan.set_discoverable(config.discoverable);
            refresh_discovery();
            Timeout.add_seconds(30, () => {
                bool paired = false;
                foreach (var d in devices.values) if (d.paired) paired = true;
                if (config.discoverable || paired) refresh_discovery();
                return Source.CONTINUE;
            });
            NetworkMonitor.get_default().network_changed.connect((available) => {
                if (available) refresh_discovery();
            });
        }

        private void save() {
            try {
                config.save();
            } catch (Error e) {
                warning("nearby: cannot save settings: %s", e.message);
            }
        }

        private Packet build_identity() {
            var p = new Packet(Packet.IDENTITY);
            p.set_string("deviceId", config.device_id);
            p.set_string("deviceName", config.device_name);
            p.set_string("deviceType", system.resolved_device_type());
            p.set_int("protocolVersion", Packet.PROTOCOL_VERSION);
            p.set_strv("incomingCapabilities", {
                Packet.PING, Packet.SHARE, Packet.SHARE_UPDATE, Packet.CLIPBOARD, Packet.CLIPBOARD_CONNECT,
                Packet.NOTIFICATION, Packet.BATTERY, Packet.BATTERY_REQUEST, Packet.FINDMYPHONE, Packet.SMS_MESSAGES,
                Packet.MPRIS, Packet.MPRIS_REQUEST, Packet.RUNCOMMAND_REQUEST
            });
            if (collab != null && collab.enabled) {
                p.set_strv("incomingCapabilities", append(p.get_strv("incomingCapabilities"), LanTransport.PACKET));
            }
            p.set_strv("outgoingCapabilities", {
                Packet.PING, Packet.SHARE, Packet.CLIPBOARD, Packet.CLIPBOARD_CONNECT, Packet.NOTIFICATION_REQUEST,
                Packet.NOTIFICATION_REPLY, Packet.NOTIFICATION_ACTION, Packet.BATTERY, Packet.BATTERY_REQUEST,
                Packet.FINDMYPHONE, Packet.SMS_REQUEST, Packet.SMS_CONVERSATIONS, Packet.SMS_CONVERSATION,
                Packet.MPRIS, Packet.MPRIS_REQUEST, Packet.RUNCOMMAND
            });
            if (collab != null && collab.enabled) {
                p.set_strv("outgoingCapabilities", append(p.get_strv("outgoingCapabilities"), LanTransport.PACKET));
            }
            return p;
        }

        private static string[] append(string[] list, string item) {
            string[] out = list;
            out += item;
            return out;
        }

        private void refresh_discovery() {
            string[] unicast = {};
            foreach (string a in system.extra_addresses) unicast += a;
            foreach (string a in added_addresses) unicast += a;
            int64 now = GLib.get_monotonic_time();
            foreach (var d in devices.values) {
                if (!d.paired || d.address == "") continue;
                if (!d.reachable || now - d.link.last_activity > IDLE_LINK * TimeSpan.SECOND) unicast += d.address;
            }
            lan.broadcast(config.discoverable, unicast);
        }

        internal void on_link(Link link) {
            var d = devices[link.device_id];
            if (d == null) {
                d = new Device(link.device_id);
                devices[link.device_id] = d;
            }
            if (d.link != null && d.link != link) {
                var old = d.link;
                d.link = null;
                old.close();
            }
            d.apply_identity(link.identity);
            d.link = link;
            d.address = link.address.to_string();
            if (d.record != null) {
                d.record.name = d.name;
                d.record.device_type = d.device_type;
                d.record.protocol_version = d.protocol_version;
                d.record.last_address = d.address;
                save();
            }
            ulong packet_handler = 0;
            ulong closed_handler = 0;
            packet_handler = link.packet_received.connect((p) => on_packet(d, p));
            closed_handler = link.closed.connect(() => {
                link.disconnect(packet_handler);
                link.disconnect(closed_handler);
                if (d.link != link) return;
                d.link = null;
                if (d.pair_state == PairState.REQUESTED || d.pair_state == PairState.INCOMING) end_pairing(d, PairState.NONE);
                foreach (var n in d.notifications.values) desktop.close(n.local_id);
                d.notifications.clear();
                d.players.clear();
                if (!d.paired) devices.unset(d.id);
                notifications_changed(d.id);
                devices_changed();
                collab.people_changed();
            });
            if (d.paired) on_connected(d);
            devices_changed();
            if (d.paired) collab.lan_connected(d.id);
        }

        private void send(Device d, Packet p) {
            if (d.link != null) d.link.send(p);
        }

        private void on_connected(Device d) {
            if (d.plugin_enabled("battery", system)) {
                send_battery(d);
                send(d, new Packet(Packet.BATTERY_REQUEST).set_bool("request", true));
            }
            if (d.plugin_enabled("clipboard", system) && last_clipboard != "") {
                send(d, new Packet(Packet.CLIPBOARD_CONNECT).set_string("content", last_clipboard).set_int("timestamp", clipboard_time));
            }
            if (d.plugin_enabled("notifications", system)) send(d, new Packet(Packet.NOTIFICATION_REQUEST).set_bool("request", true));
            if (d.plugin_enabled("mpris", system)) send(d, new Packet(Packet.MPRIS_REQUEST).set_bool("requestPlayerList", true));
            if (d.plugin_enabled("runcommand", system)) send_commands(d);
        }

        private void send_battery(Device d) {
            bool charging;
            int level = Desktop.battery_level(out charging);
            if (level < 0) return;
            send(d, new Packet(Packet.BATTERY).set_int("currentCharge", level).set_bool("isCharging", charging).set_int("thresholdEvent", 0));
        }

        private void send_commands(Device d) {
            send(d, new Packet(Packet.RUNCOMMAND).set_string("commandList", config.commands_json()).set_bool("canAddCommand", false));
        }

        private void on_packet(Device d, Packet p) {
            if (p.packet_type == Packet.PAIR) {
                handle_pair(d, p);
                return;
            }
            if (!d.paired) {
                debug("nearby: %s sent %s before pairing", d.id, p.packet_type);
                if (p.packet_type != Packet.IDENTITY) send(d, new Packet(Packet.PAIR).set_bool("pair", false));
                return;
            }
            switch (p.packet_type) {
                case Packet.PING:
                    if (d.plugin_enabled("ping", system)) {
                        desktop.send_notification.begin(d.name, Desktop.APP_ID, _("Ping from %s").printf(d.name), p.get_string("message", ""), {});
                    }
                    break;
                case Packet.SHARE:
                    if (d.plugin_enabled("share", system)) handle_share(d, p);
                    break;
                case Packet.CLIPBOARD:
                case Packet.CLIPBOARD_CONNECT:
                    if (d.plugin_enabled("clipboard", system)) handle_clipboard(d, p);
                    break;
                case Packet.NOTIFICATION:
                    if (d.plugin_enabled("notifications", system)) handle_notification.begin(d, p);
                    break;
                case Packet.BATTERY:
                    if (d.plugin_enabled("battery", system)) {
                        d.battery = (int) p.get_int("currentCharge", -1);
                        d.charging = p.get_bool("isCharging");
                        if (p.get_int("thresholdEvent", 0) == 1) {
                            desktop.send_notification.begin(d.name, Desktop.APP_ID, _("%s Battery Low").printf(d.name), _("%d%% left").printf(d.battery), {});
                        }
                        device_changed(d.id);
                    }
                    break;
                case Packet.BATTERY_REQUEST:
                    if (d.plugin_enabled("battery", system)) send_battery(d);
                    break;
                case Packet.FINDMYPHONE:
                    if (d.plugin_enabled("findmyphone", system)) {
                        var hints = new HashTable<string, Variant>(str_hash, str_equal);
                        hints["urgency"] = new Variant.byte(2);
                        hints["sound-name"] = "phone-incoming-call";
                        desktop.send_notification.begin(d.name, Desktop.APP_ID, _("%s Is Looking for This Computer").printf(d.name), _("Found it? Dismiss this notification."), {}, hints);
                    }
                    break;
                case Packet.SMS_MESSAGES:
                    if (d.plugin_enabled("sms", system)) handle_sms(d, p);
                    break;
                case Packet.MPRIS:
                    if (d.plugin_enabled("mpris", system)) handle_remote_media(d, p);
                    break;
                case Packet.MPRIS_REQUEST:
                    if (d.plugin_enabled("mpris", system)) handle_media_request.begin(d, p);
                    break;
                case Packet.RUNCOMMAND_REQUEST:
                    if (d.plugin_enabled("runcommand", system)) handle_runcommand(d, p);
                    break;
                case Packet.RUNCOMMAND:
                    d.remote_commands = { p.get_string("commandList", "{}") };
                    break;
                case LanTransport.PACKET:
                    if (collab.enabled) collab.lan.handle(d, p);
                    break;
                default:
                    break;
            }
        }

        private void handle_pair(Device d, Packet p) {
            bool want = p.get_bool("pair");
            if (want) {
                switch (d.pair_state) {
                    case PairState.REQUESTED:
                        trust(d);
                        break;
                    case PairState.INCOMING:
                        break;
                    default:
                        if (d.paired) {
                            untrust(d);
                        }
                        int64 ts = p.get_int("timestamp", -1);
                        if (ts < 0) return;
                        int64 now = get_real_time() / 1000000;
                        if ((ts - now).abs() > ALLOWED_CLOCK_SKEW) {
                            desktop.send_notification.begin(_("Nearby"), Desktop.APP_ID, _("Could Not Pair with %s").printf(d.name), _("The clocks of the two devices do not match."), {});
                            return;
                        }
                        d.pair_timestamp = ts;
                        d.verification = compute_code(d);
                        d.pair_state = PairState.INCOMING;
                        start_pair_timeout(d);
                        ask_pairing.begin(d);
                        pair_requested(d.id, d.name, d.verification);
                        break;
                }
            } else {
                if (d.pair_state == PairState.PAIRED) untrust(d);
                else end_pairing(d, PairState.NONE);
            }
            devices_changed();
        }

        private string compute_code(Device d) {
            try {
                var peer = NearbyCerts.public_key_der(d.certificate_pem);
                return Packet.verification_code(own_public_key, peer, d.pair_timestamp);
            } catch (Error e) {
                return "";
            }
        }

        private async void ask_pairing(Device d) {
            d.pair_notification = yield desktop.send_notification(d.name, Desktop.APP_ID,
                _("Pair with %s?").printf(d.name),
                _("Check that %s shows the code %s.").printf(d.name, d.verification),
                { "accept", _("Pair"), "reject", _("Decline") }, null, 0,
                (action) => {
                    if (action == "accept") accept_pair_internal(d);
                    else if (action == "reject") reject_pair_internal(d);
                }, null, null, 0);
        }

        private void start_pair_timeout(Device d) {
            if (d.pair_timeout != 0) Source.remove(d.pair_timeout);
            d.pair_timeout = Timeout.add_seconds(PAIR_TIMEOUT, () => {
                d.pair_timeout = 0;
                if (d.pair_state == PairState.REQUESTED || d.pair_state == PairState.INCOMING) {
                    send(d, new Packet(Packet.PAIR).set_bool("pair", false));
                    end_pairing(d, PairState.NONE);
                    devices_changed();
                }
                return Source.REMOVE;
            });
        }

        private void end_pairing(Device d, PairState state) {
            if (d.pair_timeout != 0) Source.remove(d.pair_timeout);
            d.pair_timeout = 0;
            if (d.pair_notification != 0) desktop.close(d.pair_notification);
            d.pair_notification = 0;
            d.pair_state = state;
            if (state != PairState.PAIRED) d.verification = "";
        }

        private void trust(Device d) {
            end_pairing(d, PairState.PAIRED);
            var r = new DeviceRecord(d.id);
            r.name = d.name;
            r.device_type = d.device_type;
            r.certificate = d.link != null ? d.link.peer_certificate_pem : "";
            r.protocol_version = d.protocol_version;
            r.last_address = d.address;
            d.record = r;
            config.trusted[d.id] = r;
            save();
            if (d.reachable) on_connected(d);
            devices_changed();
        }

        private void untrust(Device d) {
            end_pairing(d, PairState.NONE);
            config.forget(d.id);
            d.record = null;
            save();
            foreach (var n in d.notifications.values) desktop.close(n.local_id);
            d.notifications.clear();
            notifications_changed(d.id);
            d.threads.clear();
            d.players.clear();
            d.battery = -1;
            if (!d.reachable) devices.unset(d.id);
            devices_changed();
        }

        private void accept_pair_internal(Device d) {
            if (d.pair_state != PairState.INCOMING) return;
            send(d, new Packet(Packet.PAIR).set_bool("pair", true));
            trust(d);
        }

        private void reject_pair_internal(Device d) {
            if (d.pair_state != PairState.INCOMING && d.pair_state != PairState.REQUESTED) return;
            send(d, new Packet(Packet.PAIR).set_bool("pair", false));
            end_pairing(d, PairState.NONE);
            devices_changed();
        }

        private void handle_clipboard(Device d, Packet p) {
            string? content = p.get_string("content");
            if (content == null || content == "") return;
            if (p.packet_type == Packet.CLIPBOARD_CONNECT) {
                int64 ts = p.get_int("timestamp", 0);
                if (ts == 0 || ts < clipboard_time) return;
            }
            if (content == last_clipboard) return;
            last_clipboard = content;
            clipboard_time = get_real_time() / 1000;
            foreach (var other in devices.values) {
                if (other != d && other.reachable && other.plugin_enabled("clipboard", system)) {
                    send(other, new Packet(Packet.CLIPBOARD).set_string("content", content));
                }
            }
            clipboard_received(content, d.id);
        }

        private async void handle_notification(Device d, Packet p) {
            string key = p.get_string("id", "");
            if (key == "") return;
            if (p.get_bool("isCancel")) {
                var gone = d.notifications[key];
                if (gone != null) {
                    gone.closing = true;
                    d.notifications.unset(key);
                    desktop.close(gone.local_id);
                    notifications_changed(d.id);
                }
                return;
            }
            if (p.get_bool("silent") && !d.notifications.has_key(key)) return;
            var n = d.notifications[key] ?? new PhoneNotification(key);
            n.app_name = p.get_string("appName", d.name);
            n.title = p.get_string("title", p.get_string("ticker", ""));
            n.text = p.get_string("text", "");
            n.reply_id = p.get_string("requestReplyId", "");
            n.clearable = p.get_bool("isClearable", true);
            n.actions = p.get_strv("actions");
            n.time = p.get_int("time", get_real_time() / 1000);
            string? hash = p.get_string("payloadHash");
            if (p.has_payload && hash != null && d.link != null) {
                string safe = Files.safe_name(hash);
                string path = Path.build_filename(Files.icon_dir(), safe + ".png");
                if (!FileUtils.test(path, FileTest.EXISTS)) {
                    try {
                        yield download(d, p, path + ".part", null, null);
                        FileUtils.rename(path + ".part", path);
                    } catch (Error e) {
                        FileUtils.remove(path + ".part");
                    }
                }
                if (FileUtils.test(path, FileTest.EXISTS)) n.icon_path = path;
            }
            d.notifications[key] = n;
            notifications_changed(d.id);
            string[] actions = {};
            if (n.reply_id != "") {
                actions += "inline-reply";
                actions += _("Reply");
            }
            foreach (string a in n.actions) {
                actions += "action:" + a;
                actions += a;
            }
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            if (n.icon_path != "") hints["image-path"] = n.icon_path;
            hints["x-singularity-nearby-device"] = d.id;
            if (n.reply_id != "") hints["x-kde-reply-placeholder-text"] = _("Reply on %s").printf(d.name);
            string summary = n.title != "" ? n.title : n.app_name;
            uint32 previous = n.local_id;
            n.local_id = yield desktop.send_notification(n.app_name, Desktop.APP_ID, summary, n.text, actions, hints, previous,
                (action) => {
                    if (action.has_prefix("action:")) {
                        send(d, new Packet(Packet.NOTIFICATION_ACTION).set_string("key", key).set_string("action", action.substring(7)));
                    }
                },
                (text) => {
                    if (n.reply_id != "") send(d, new Packet(Packet.NOTIFICATION_REPLY).set_string("requestReplyId", n.reply_id).set_string("message", text));
                },
                (reason) => {
                    if (n.closing) return;
                    if (reason == 2 && n.clearable && d.notifications.has_key(key)) {
                        d.notifications.unset(key);
                        send(d, new Packet(Packet.NOTIFICATION_REQUEST).set_string("cancel", key));
                        notifications_changed(d.id);
                    }
                });
        }

        private void handle_share(Device d, Packet p) {
            if (p.has("text")) {
                string text = p.get_string("text", "");
                desktop.send_notification.begin(d.name, Desktop.APP_ID, _("Text from %s").printf(d.name), text, { "copy", _("Copy") }, null, 0, (action) => {
                    if (action == "copy") {
                        last_clipboard = text;
                        clipboard_received(text, d.id);
                    }
                });
                return;
            }
            if (p.has("url")) {
                string url = p.get_string("url", "");
                string? scheme = Uri.peek_scheme(url);
                if (scheme == null || !(scheme in OPENABLE_SCHEMES)) return;
                desktop.send_notification.begin(d.name, Desktop.APP_ID, _("Link from %s").printf(d.name), url, { "open", _("Open"), "copy", _("Copy") }, null, 0, (action) => {
                    if (action == "open") Desktop.open_uri(url);
                    else if (action == "copy") {
                        last_clipboard = url;
                        clipboard_received(url, d.id);
                    }
                });
                return;
            }
            if (!p.has_payload) return;
            string name = Files.safe_name(p.get_string("filename", "file"));
            var batch = batches[d.id];
            if (batch == null) {
                batch = new IncomingBatch(Uuid.string_random(), d.id);
                batches[d.id] = batch;
                if (d.record != null && d.record.always_allow_files) batch.decision = Decision.ACCEPTED;
            }
            string fid = Uuid.string_random();
            var file = new IncomingFile(fid, name, p.payload_size, Path.build_filename(Files.staging_dir(), fid + ".part"));
            file.open_after = p.get_bool("open");
            batch.files.add(file);
            var info = track(fid, d.id, name, p.payload_size, true);
            info.batch = batch.id;
            if (batch.decision == Decision.UNDECIDED) info.state = "waiting";
            transfer_started(fid, d.id, name, p.payload_size, true);
            if (batch.decision == Decision.UNDECIDED) ask_files.begin(d, batch);
            receive_file.begin(d, p, batch, file);
        }

        private async void ask_files(Device d, IncomingBatch batch) {
            string summary = batch.files.size == 1 ? batch.files[0].filename
                : ngettext("%d file", "%d files", batch.files.size).printf(batch.files.size);
            string detail = batch.total_size > 0 ? "%s, %s".printf(summary, format_size(batch.total_size)) : summary;
            transfer_requested(batch.id, d.id, summary, batch.total_size);
            if (batch.timeout == 0) {
                batch.timeout = Timeout.add_seconds(600, () => {
                    batch.timeout = 0;
                    if (batch.decision == Decision.UNDECIDED) decide(batch, Decision.DECLINED, false);
                    return Source.REMOVE;
                });
            }
            batch.notification = yield desktop.send_notification(d.name, Desktop.APP_ID,
                _("%s Wants to Send You Files").printf(d.name), detail,
                { "accept", _("Accept"), "always", _("Always Allow"), "decline", _("Decline") }, null, batch.notification,
                (action) => {
                    if (action == "accept") decide(batch, Decision.ACCEPTED, false);
                    else if (action == "always") decide(batch, Decision.ACCEPTED, true);
                    else if (action == "decline") decide(batch, Decision.DECLINED, false);
                }, null, (reason) => {
                    if (reason == 2 && batch.decision == Decision.UNDECIDED) decide(batch, Decision.DECLINED, false);
                }, 0);
        }

        private void decide(IncomingBatch batch, Decision decision, bool always) {
            if (batch.decision != Decision.UNDECIDED) return;
            batch.decision = decision;
            if (batch.timeout != 0) Source.remove(batch.timeout);
            batch.timeout = 0;
            if (batch.notification != 0) desktop.close(batch.notification);
            var d = devices[batch.device_id];
            if (always && d != null && d.record != null) {
                d.record.always_allow_files = true;
                save();
                device_changed(d.id);
            }
            foreach (var f in batch.files) {
                var info = find_transfer(f.id);
                if (info != null && info.state == "waiting") info.state = "running";
                if (decision == Decision.DECLINED) {
                    f.cancellable.cancel();
                    FileUtils.remove(f.staging);
                    transfer_finished(f.id, false, _("Declined"));
                } else if (f.complete) {
                    finalize_file(d, f);
                }
            }
            if (batches[batch.device_id] == batch) batches.unset(batch.device_id);
        }

        private async void receive_file(Device d, Packet p, IncomingBatch batch, IncomingFile file) {
            try {
                yield download(d, p, file.staging, file.cancellable, (done, total) => transfer_progress(file.id, done, total));
                file.complete = true;
                if (batch.decision == Decision.ACCEPTED) finalize_file(d, file);
                else if (batch.decision == Decision.DECLINED) FileUtils.remove(file.staging);
                if (batches[batch.device_id] == batch && batch.decision == Decision.ACCEPTED) {
                    bool all = true;
                    foreach (var f in batch.files) if (!f.complete && !f.failed) all = false;
                    if (all) batches.unset(batch.device_id);
                }
            } catch (Error e) {
                file.failed = true;
                FileUtils.remove(file.staging);
                if (!(e is IOError.CANCELLED)) {
                    transfer_finished(file.id, false, e.message);
                    if (batch.decision == Decision.ACCEPTED) {
                        desktop.send_notification.begin(d.name, Desktop.APP_ID, _("Could Not Receive %s").printf(file.filename), e.message, {});
                    }
                }
            }
        }

        private void finalize_file(Device? d, IncomingFile f) {
            string folder = config.receive_folder != "" ? config.receive_folder : UserConfig.default_receive_folder();
            DirUtils.create_with_parents(folder, 0755);
            string target = Files.unique_path(folder, f.filename);
            try {
                File.new_for_path(f.staging).move(File.new_for_path(target), FileCopyFlags.NONE, null, null);
                FileUtils.chmod(target, 0644);
                f.final_path = target;
                history.add(target, d != null ? d.id : "", d != null ? d.name : "");
                transfer_finished(f.id, true, target);
                announce_received(target, d != null ? d.name : "");
            } catch (Error e) {
                FileUtils.remove(f.staging);
                transfer_finished(f.id, false, e.message);
            }
        }

        private void announce_received(string path, string from) {
            string uri = File.new_for_path(path).get_uri();
            desktop.send_notification.begin(_("Nearby"), Desktop.APP_ID, _("Received %s").printf(Path.get_basename(path)),
                from != "" ? _("From %s").printf(from) : "", { "default", _("Open"), "open", _("Open"), "show", _("Show in Files") }, null, 0,
                (action) => {
                    if (action == "open" || action == "default") Desktop.open_uri(uri);
                    else if (action == "show") desktop.show_in_files(uri);
                });
        }

        private async void download(Device d, Packet p, string target, Cancellable? cancellable, owned ProgressFunc? progress) throws Error {
            if (d.link == null) throw new IOError.NOT_CONNECTED("not connected");
            var own = Tls.own_certificate(config);
            var tls = yield connect_payload(d.link.address, p.payload_port, own, d.certificate_pem, cancellable);
            var out_file = File.new_for_path(target);
            var stream = yield out_file.replace_async(null, false, FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION, Priority.DEFAULT, cancellable);
            try {
                yield copy(tls.input_stream, stream, p.payload_size, cancellable, (owned) progress);
            } finally {
                try {
                    yield stream.close_async(Priority.DEFAULT, null);
                    yield tls.close_async(Priority.DEFAULT, null);
                } catch (Error e) {
                }
            }
        }

        private void handle_sms(Device d, Packet p) {
            var messages = p.get_array("messages");
            if (messages == null) return;
            messages.foreach_element((a, i, node) => {
                if (node.get_node_type() != Json.NodeType.OBJECT) return;
                var o = node.get_object();
                var m = new SmsMessage();
                m.id = json_int(o, "_id");
                m.thread = json_int(o, "thread_id");
                m.body = o.get_string_member_with_default("body", "");
                m.date = json_int(o, "date");
                m.kind = (int) json_int(o, "type");
                m.read = json_int(o, "read") != 0 || (o.has_member("read") && o.get_member("read").get_value_type() == typeof(bool) && o.get_boolean_member("read"));
                if (o.has_member("addresses") && o.get_member("addresses").get_node_type() == Json.NodeType.ARRAY) {
                    var addrs = o.get_array_member("addresses");
                    string[] list = {};
                    addrs.foreach_element((b, j, an) => {
                        if (an.get_node_type() == Json.NodeType.OBJECT) list += an.get_object().get_string_member_with_default("address", "");
                    });
                    m.address = string.joinv(", ", list);
                } else {
                    m.address = o.get_string_member_with_default("address", "");
                }
                d.store_message(m);
            });
            conversations_changed(d.id);
        }

        private static int64 json_int(Json.Object o, string key) {
            if (!o.has_member(key)) return 0;
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return 0;
            var t = n.get_value_type();
            if (t == typeof(int64)) return n.get_int();
            if (t == typeof(double)) return (int64) n.get_double();
            if (t == typeof(string)) {
                int64 v;
                if (int64.try_parse(n.get_string(), out v)) return v;
            }
            return 0;
        }

        private void handle_remote_media(Device d, Packet p) {
            if (p.has("playerList")) {
                var names = new Gee.HashSet<string>();
                foreach (string n in p.get_strv("playerList")) {
                    names.add(n);
                    if (!d.players.has_key(n)) {
                        d.players[n] = new MediaPlayer(n);
                        send(d, new Packet(Packet.MPRIS_REQUEST).set_string("player", n).set_bool("requestNowPlaying", true).set_bool("requestVolume", true));
                    }
                }
                foreach (string existing in d.players.keys.to_array()) if (!names.contains(existing)) d.players.unset(existing);
            }
            string? player = p.get_string("player");
            if (player != null && d.players.has_key(player)) {
                var m = d.players[player];
                if (p.has("title")) m.title = p.get_string("title", "");
                if (p.has("artist")) m.artist = p.get_string("artist", "");
                if (p.has("album")) m.album = p.get_string("album", "");
                if (p.has("isPlaying")) m.playing = p.get_bool("isPlaying");
                if (p.has("canPlay")) m.can_play = p.get_bool("canPlay");
                if (p.has("canPause")) m.can_pause = p.get_bool("canPause");
                if (p.has("canGoNext")) m.can_next = p.get_bool("canGoNext");
                if (p.has("canGoPrevious")) m.can_previous = p.get_bool("canGoPrevious");
                if (p.has("length")) m.length = p.get_int("length");
                if (p.has("pos")) m.position = p.get_int("pos");
                if (p.has("volume")) m.volume = (int) p.get_int("volume", 100);
            }
            media_changed(d.id);
            device_changed(d.id);
        }

        private async void handle_media_request(Device d, Packet p) {
            if (p.get_bool("requestPlayerList")) {
                string[] names = yield media.refresh();
                send(d, new Packet(Packet.MPRIS).set_strv("playerList", names).set_bool("supportAlbumArtPayload", false));
            }
            string? player = p.get_string("player");
            if (player == null) return;
            if (p.has("action") || p.has("setVolume") || p.has("Seek")) yield media.control(p);
            if (p.get_bool("requestNowPlaying") || p.get_bool("requestVolume") || p.has("action")) {
                var state = yield media.now_playing(player);
                if (state != null) send(d, state);
            }
        }

        private void on_local_media_changed(string player) {
            foreach (var d in devices.values) {
                if (!d.reachable || !d.plugin_enabled("mpris", system)) continue;
                media.now_playing.begin(player, (o, r) => {
                    var state = media.now_playing.end(r);
                    if (state != null) send(d, state);
                });
            }
        }

        private void handle_runcommand(Device d, Packet p) {
            if (p.get_bool("requestCommandList")) {
                send_commands(d);
                return;
            }
            string? key = p.get_string("key");
            if (key == null) return;
            foreach (var c in config.commands) {
                if (c.key != key) continue;
                try {
                    string[] argv = { "/bin/sh", "-c", c.command };
                    Process.spawn_async(Environment.get_home_dir(), argv, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL, null, null);
                } catch (SpawnError e) {
                    warning("nearby: command %s: %s", c.name, e.message);
                }
                return;
            }
        }

        private void ask_bluetooth(string transfer, string device, string filename, int64 size, owned Answer answer) {
            bool decided = false;
            uint32 nid = 0;
            uint guard = 0;
            Answer settle = (ok) => {
                if (decided) return;
                decided = true;
                if (guard != 0) Source.remove(guard);
                guard = 0;
                pending_bluetooth.unset(transfer);
                answer(ok);
            };
            var pending = new PendingAnswer();
            pending.answer = (ok) => {
                desktop.close(nid);
                settle(ok);
            };
            pending_bluetooth[transfer] = pending;
            guard = Timeout.add_seconds(60, () => {
                guard = 0;
                desktop.close(nid);
                settle(false);
                return Source.REMOVE;
            });
            string detail = size > 0 ? "%s, %s".printf(filename, format_size(size)) : filename;
            transfer_requested(transfer, device, filename, size);
            desktop.send_notification.begin(_("Bluetooth"), Desktop.APP_ID,
                device != "" ? _("%s Wants to Send You a File").printf(device) : _("Incoming File over Bluetooth"), detail,
                { "accept", _("Accept"), "decline", _("Decline") }, null, 0,
                (action) => settle(action == "accept"), null, (reason) => settle(false), 0, (o, r) => {
                    nid = desktop.send_notification.end(r);
                    if (decided) desktop.close(nid);
                });
        }

        private Gee.HashMap<string, PendingAnswer> pending_bluetooth = new Gee.HashMap<string, PendingAnswer>();

        private Device require(string id) throws NearbyError {
            var d = devices[id];
            if (d == null) throw new NearbyError.NOT_FOUND(_("There is no device %s").printf(id));
            return d;
        }

        private Device require_paired(string id, string? plugin = null) throws NearbyError {
            var d = require(id);
            if (!d.paired) throw new NearbyError.NOT_PAIRED(_("%s is not paired").printf(d.name));
            if (!d.reachable) throw new NearbyError.NOT_REACHABLE(_("%s is not connected").printf(d.name));
            if (plugin != null && !d.plugin_enabled(plugin, system)) throw new NearbyError.DISABLED(_("This feature is off for %s").printf(d.name));
            return d;
        }

        public HashTable<string, Variant>[] list_devices() throws DBusError, IOError {
            HashTable<string, Variant>[] result = {};
            var sorted = new Gee.ArrayList<Device>();
            sorted.add_all(devices.values);
            sorted.sort((a, b) => a.paired != b.paired ? (a.paired ? -1 : 1) : strcmp(a.name.collate_key(), b.name.collate_key()));
            foreach (var d in sorted) result += d.to_dict(system);
            return result;
        }

        public HashTable<string, Variant> get_device(string id) throws NearbyError, DBusError, IOError {
            return require(id).to_dict(system);
        }

        public void refresh() throws DBusError, IOError {
            refresh_discovery();
        }

        public void connect_address(string address) throws DBusError, IOError {
            if (!(address in added_addresses)) added_addresses.add(address);
            refresh_discovery();
        }

        public void request_pair(string id) throws NearbyError, DBusError, IOError {
            var d = require(id);
            if (!d.reachable) throw new NearbyError.NOT_REACHABLE(_("%s is not connected").printf(d.name));
            if (d.paired) return;
            if (d.pair_state == PairState.INCOMING) {
                accept_pair_internal(d);
                return;
            }
            d.pair_timestamp = get_real_time() / 1000000;
            d.verification = compute_code(d);
            d.pair_state = PairState.REQUESTED;
            start_pair_timeout(d);
            send(d, new Packet(Packet.PAIR).set_bool("pair", true).set_int("timestamp", d.pair_timestamp));
            devices_changed();
        }

        public void accept_pair(string id) throws NearbyError, DBusError, IOError {
            accept_pair_internal(require(id));
        }

        public void reject_pair(string id) throws NearbyError, DBusError, IOError {
            reject_pair_internal(require(id));
        }

        public void unpair(string id) throws NearbyError, DBusError, IOError {
            var d = require(id);
            send(d, new Packet(Packet.PAIR).set_bool("pair", false));
            untrust(d);
        }

        public void ping(string id, string message) throws NearbyError, DBusError, IOError {
            var p = new Packet(Packet.PING);
            if (message != "") p.set_string("message", message);
            send(require_paired(id, "ping"), p);
        }

        public void ring(string id) throws NearbyError, DBusError, IOError {
            send(require_paired(id, "findmyphone"), new Packet(Packet.FINDMYPHONE));
        }

        public void share_url(string id, string url) throws NearbyError, DBusError, IOError {
            send(require_paired(id, "share"), new Packet(Packet.SHARE).set_string("url", url));
        }

        public void share_text(string id, string text) throws NearbyError, DBusError, IOError {
            send(require_paired(id, "share"), new Packet(Packet.SHARE).set_string("text", text));
        }

        public string share_files(string id, string[] uris) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "share");
            if (uris.length == 0) throw new NearbyError.FAILED(_("Nothing to send"));
            string tid = Uuid.string_random();
            string label = uris.length == 1 ? Path.get_basename(File.new_for_uri(uris[0]).get_path() ?? uris[0])
                : ngettext("%d file", "%d files", uris.length).printf(uris.length);
            track(tid, d.id, label, 0, false);
            transfer_started(tid, d.id, label, 0, false);
            send_files.begin(d, tid, uris);
            return tid;
        }

        private async void send_files(Device d, string tid, owned string[] uris) {
            int64 total = 0;
            var files = new Gee.ArrayList<File>();
            foreach (string u in uris) {
                var f = File.new_for_uri(u);
                files.add(f);
                try {
                    total += (yield f.query_info_async(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, Priority.DEFAULT, null)).get_size();
                } catch (Error e) {
                }
            }
            int64 before = 0;
            try {
                var own = Tls.own_certificate(config);
                foreach (var f in files) {
                    if (!d.reachable) throw new IOError.NOT_CONNECTED(_("%s is no longer connected").printf(d.name));
                    var info = yield f.query_info_async(FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_DISPLAY_NAME + "," + FileAttribute.TIME_MODIFIED + "," + FileAttribute.STANDARD_TYPE,
                        FileQueryInfoFlags.NONE, Priority.DEFAULT, null);
                    if (info.get_file_type() != FileType.REGULAR) throw new IOError.NOT_REGULAR_FILE(_("%s is not a file").printf(info.get_display_name()));
                    int64 size = info.get_size();
                    var server = new PayloadServer(system);
                    var p = new Packet(Packet.SHARE);
                    p.set_string("filename", info.get_display_name());
                    p.set_int("lastModified", (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED) * 1000);
                    p.set_int("numberOfFiles", files.size);
                    p.set_int("totalPayloadSize", total);
                    p.payload_size = size;
                    p.payload_port = server.port;
                    var stream = yield f.read_async(Priority.DEFAULT, null);
                    send(d, p);
                    int64 base_done = before;
                    yield server.serve(stream, size, own, d.certificate_pem, null, (done, t) => transfer_progress(tid, base_done + done, total));
                    before += size;
                    transfer_progress(tid, before, total);
                }
                transfer_finished(tid, true, "");
            } catch (Error e) {
                transfer_finished(tid, false, e.message);
            }
        }

        public void send_clipboard(string text) throws DBusError, IOError {
            if (text == "" || text == last_clipboard) return;
            last_clipboard = text;
            clipboard_time = get_real_time() / 1000;
            foreach (var d in devices.values) {
                if (d.reachable && d.plugin_enabled("clipboard", system)) send(d, new Packet(Packet.CLIPBOARD).set_string("content", text));
            }
        }

        public void set_plugin_enabled(string id, string plugin, bool enabled) throws NearbyError, DBusError, IOError {
            var d = require(id);
            if (!d.paired) throw new NearbyError.NOT_PAIRED(_("%s is not paired").printf(d.name));
            if (!(plugin in Device.PLUGINS)) throw new NearbyError.NOT_FOUND(_("Unknown feature %s").printf(plugin));
            d.set_plugin(plugin, enabled);
            save();
            if (enabled && d.reachable) on_connected(d);
            device_changed(id);
        }

        public void set_always_allow_files(string id, bool allow) throws NearbyError, DBusError, IOError {
            var d = require(id);
            if (d.record == null) throw new NearbyError.NOT_PAIRED(_("%s is not paired").printf(d.name));
            d.record.always_allow_files = allow;
            save();
            device_changed(id);
        }

        public void accept_transfer(string batch_id, bool always) throws NearbyError, DBusError, IOError {
            if (pending_bluetooth.has_key(batch_id)) {
                pending_bluetooth[batch_id].answer(true);
                return;
            }
            foreach (var b in batches.values) {
                if (b.id == batch_id) {
                    decide(b, Decision.ACCEPTED, always);
                    return;
                }
            }
            throw new NearbyError.NOT_FOUND(_("That transfer is no longer waiting"));
        }

        public void reject_transfer(string batch_id) throws NearbyError, DBusError, IOError {
            if (pending_bluetooth.has_key(batch_id)) {
                pending_bluetooth[batch_id].answer(false);
                return;
            }
            foreach (var b in batches.values) {
                if (b.id == batch_id) {
                    decide(b, Decision.DECLINED, false);
                    return;
                }
            }
            throw new NearbyError.NOT_FOUND(_("That transfer is no longer waiting"));
        }

        public void request_conversations(string id) throws NearbyError, DBusError, IOError {
            send(require_paired(id, "sms"), new Packet(Packet.SMS_CONVERSATIONS));
        }

        public void request_conversation(string id, int64 thread) throws NearbyError, DBusError, IOError {
            send(require_paired(id, "sms"), new Packet(Packet.SMS_CONVERSATION).set_int("threadID", thread));
        }

        public HashTable<string, Variant>[] get_conversations(string id) throws NearbyError, DBusError, IOError {
            var d = require(id);
            var latest = new Gee.ArrayList<SmsMessage>();
            foreach (var list in d.threads.values) if (list.size > 0) latest.add(list[list.size - 1]);
            latest.sort((a, b) => a.date > b.date ? -1 : (a.date < b.date ? 1 : 0));
            HashTable<string, Variant>[] result = {};
            foreach (var m in latest) result += m.to_dict();
            return result;
        }

        public HashTable<string, Variant>[] get_messages(string id, int64 thread) throws NearbyError, DBusError, IOError {
            var d = require(id);
            HashTable<string, Variant>[] result = {};
            var list = d.threads[thread.to_string()];
            if (list != null) foreach (var m in list) result += m.to_dict();
            return result;
        }

        public void send_sms(string id, string address, string body) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "sms");
            if (address.strip() == "" || body.strip() == "") throw new NearbyError.FAILED(_("A number and a message are needed"));
            var p = new Packet(Packet.SMS_REQUEST);
            p.set_bool("sendSms", true);
            p.set_string("phoneNumber", address);
            p.set_string("messageBody", body);
            p.set_int("version", 2);
            var arr = new Json.Array();
            var a = new Json.Object();
            a.set_string_member("address", address);
            arr.add_object_element(a);
            p.body.set_array_member("addresses", arr);
            send(d, p);
        }

        public HashTable<string, Variant>[] get_players(string id) throws NearbyError, DBusError, IOError {
            var d = require(id);
            HashTable<string, Variant>[] result = {};
            foreach (var m in d.players.values) result += m.to_dict();
            return result;
        }

        public void media_action(string id, string player, string action) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "mpris");
            if (!(action in LocalMedia.ACTIONS)) throw new NearbyError.FAILED(_("Unknown action %s").printf(action));
            send(d, new Packet(Packet.MPRIS_REQUEST).set_string("player", player).set_string("action", action));
        }

        public HashTable<string, Variant>[] list_commands() throws DBusError, IOError {
            HashTable<string, Variant>[] result = {};
            foreach (var c in config.commands) {
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["key"] = c.key;
                d["name"] = c.name;
                d["command"] = c.command;
                result += d;
            }
            return result;
        }

        public string add_command(string name, string command) throws NearbyError, DBusError, IOError {
            if (name.strip() == "" || command.strip() == "") throw new NearbyError.FAILED(_("A name and a command are needed"));
            var c = new RunCommand(Uuid.string_random().replace("-", ""), name.strip(), command.strip());
            config.commands.add(c);
            save();
            foreach (var d in devices.values) if (d.reachable && d.plugin_enabled("runcommand", system)) send_commands(d);
            return c.key;
        }

        public void remove_command(string key) throws DBusError, IOError {
            foreach (var c in config.commands) {
                if (c.key == key) {
                    config.commands.remove(c);
                    save();
                    break;
                }
            }
            foreach (var d in devices.values) if (d.reachable && d.plugin_enabled("runcommand", system)) send_commands(d);
        }

        public async HashTable<string, Variant>[] list_bluetooth_devices() throws DBusError, IOError {
            return yield Obex.bluetooth_devices();
        }

        public string bluetooth_send_files(string address, string[] uris) throws NearbyError, DBusError, IOError {
            if (!obex.available) throw new NearbyError.DISABLED(_("Bluetooth file transfer is not available on this system"));
            if (uris.length == 0) throw new NearbyError.FAILED(_("Nothing to send"));
            string tid = Uuid.string_random();
            string label = uris.length == 1 ? Path.get_basename(File.new_for_uri(uris[0]).get_path() ?? uris[0])
                : ngettext("%d file", "%d files", uris.length).printf(uris.length);
            track(tid, "bluetooth:" + address, label, 0, false);
            transfer_started(tid, "bluetooth:" + address, label, 0, false);
            obex.send_files.begin(tid, address, uris);
            return tid;
        }

        private TransferInfo? find_transfer(string id) {
            foreach (var t in transfers) if (t.id == id) return t;
            return null;
        }

        private TransferInfo track(string id, string device_id, string name, int64 size, bool incoming) {
            var t = new TransferInfo(id);
            t.device_id = device_id;
            t.name = name;
            t.total = size;
            t.incoming = incoming;
            transfers.insert(0, t);
            while (transfers.size > 40) {
                int drop = -1;
                for (int i = transfers.size - 1; i >= 0; i--) {
                    if (transfers[i].state != "running" && transfers[i].state != "waiting") {
                        drop = i;
                        break;
                    }
                }
                if (drop < 0) break;
                transfers.remove_at(drop);
            }
            return t;
        }

        private void on_transfer_progress(string id, int64 done, int64 total) {
            var t = find_transfer(id);
            if (t == null) return;
            t.done = done;
            if (total > 0) t.total = total;
        }

        private void on_transfer_finished(string id, bool ok, string detail) {
            var t = find_transfer(id);
            if (t == null) return;
            t.state = ok ? "done" : "failed";
            t.detail = detail;
            if (ok && t.total > 0) t.done = t.total;
        }

        public HashTable<string, Variant>[] get_transfers() throws DBusError, IOError {
            HashTable<string, Variant>[] result = {};
            foreach (var t in transfers) result += t.to_dict();
            return result;
        }

        public HashTable<string, Variant>[] get_notifications(string id) throws NearbyError, DBusError, IOError {
            var d = require(id);
            var sorted = new Gee.ArrayList<PhoneNotification>();
            sorted.add_all(d.notifications.values);
            sorted.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            HashTable<string, Variant>[] result = {};
            foreach (var n in sorted) result += n.to_dict();
            return result;
        }

        public void dismiss_notification(string id, string key) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "notifications");
            var n = d.notifications[key];
            if (n == null) throw new NearbyError.NOT_FOUND(_("That notification is gone"));
            if (!n.clearable) throw new NearbyError.FAILED(_("This notification cannot be dismissed"));
            n.closing = true;
            d.notifications.unset(key);
            desktop.close(n.local_id);
            send(d, new Packet(Packet.NOTIFICATION_REQUEST).set_string("cancel", key));
            notifications_changed(d.id);
        }

        public void reply_notification(string id, string key, string message) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "notifications");
            var n = d.notifications[key];
            if (n == null) throw new NearbyError.NOT_FOUND(_("That notification is gone"));
            if (n.reply_id == "" || message.strip() == "") throw new NearbyError.FAILED(_("This notification takes no reply"));
            send(d, new Packet(Packet.NOTIFICATION_REPLY).set_string("requestReplyId", n.reply_id).set_string("message", message));
        }

        public void activate_notification_action(string id, string key, string action) throws NearbyError, DBusError, IOError {
            var d = require_paired(id, "notifications");
            var n = d.notifications[key];
            if (n == null || !(action in n.actions)) throw new NearbyError.NOT_FOUND(_("That notification is gone"));
            send(d, new Packet(Packet.NOTIFICATION_ACTION).set_string("key", key).set_string("action", action));
        }

        public HashTable<string, Variant>[] get_received_files() throws DBusError, IOError {
            HashTable<string, Variant>[] result = {};
            foreach (var e in history.entries) result += e.to_dict();
            return result;
        }

        public void forget_received_file(string path) throws DBusError, IOError {
            history.forget(path);
        }

        public void clear_received_files() throws DBusError, IOError {
            history.clear();
        }
    }
}
