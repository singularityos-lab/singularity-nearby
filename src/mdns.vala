namespace Singularity.Nearby {

    public class DnsName {
        public static void write(ByteArray out_buf, string name) {
            foreach (string label in name.split(".")) {
                if (label == "") continue;
                uint8 len = (uint8) int.min(label.length, 63);
                out_buf.append({ len });
                out_buf.append(label.data[0:len]);
            }
            out_buf.append({ 0 });
        }

        public static string? read(uint8[] data, ref int pos) {
            var sb = new StringBuilder();
            int p = pos;
            bool jumped = false;
            int hops = 0;
            while (p < data.length) {
                uint8 len = data[p];
                if (len == 0) {
                    p++;
                    break;
                }
                if ((len & 0xc0) == 0xc0) {
                    if (p + 1 >= data.length || ++hops > 32) return null;
                    int target = ((len & 0x3f) << 8) | data[p + 1];
                    if (!jumped) pos = p + 2;
                    jumped = true;
                    p = target;
                    continue;
                }
                if (p + 1 + len > data.length) return null;
                if (sb.len > 0) sb.append_c('.');
                sb.append(((string) data[p + 1:p + 1 + len]).make_valid(len));
                p += 1 + len;
            }
            if (!jumped) pos = p;
            return sb.str;
        }
    }

    public class Mdns : Object {
        public const string SERVICE = "_kdeconnect._udp.local";
        public const string GROUP = "224.0.0.251";
        public const uint16 PORT = 5353;
        private const uint16 TYPE_A = 1;
        private const uint16 TYPE_PTR = 12;
        private const uint16 TYPE_TXT = 16;
        private const uint16 TYPE_SRV = 33;

        public string instance { get; set; }
        public string device_name { get; set; }
        public string device_type { get; set; }
        public int tcp_port { get; set; }
        public bool announcing { get; set; default = true; }

        private Socket? socket;
        private SocketSource? source;

        public signal void found(InetAddress address, int port, string device_id, int protocol);

        public bool start() {
            try {
                socket = new Socket(SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                socket.set_option(1, 15, 1);
                socket.bind(new InetSocketAddress(new InetAddress.any(SocketFamily.IPV4), PORT), true);
                socket.multicast_loopback = true;
                socket.multicast_ttl = 255;
                var group = new InetAddress.from_string(GROUP);
                bool joined = false;
                foreach (string entry in NearbyNetif.list()) {
                    string[] f = entry.split("\t");
                    try {
                        socket.join_multicast_group(group, false, f[0]);
                        joined = true;
                    } catch (Error e) {
                        debug("mdns: join on %s: %s", f[0], e.message);
                    }
                }
                if (!joined) socket.join_multicast_group(group, false, null);
                source = socket.create_source(IOCondition.IN, null);
                source.set_callback((s, cond) => {
                    receive();
                    return Source.CONTINUE;
                });
                source.attach(MainContext.get_thread_default());
                return true;
            } catch (Error e) {
                warning("mdns: %s", e.message);
                socket = null;
                return false;
            }
        }

        public void stop() {
            if (source != null) source.destroy();
            source = null;
            if (socket != null) {
                try {
                    socket.close();
                } catch (Error e) {
                }
            }
            socket = null;
        }

        private static void put16(ByteArray b, uint16 v) {
            b.append({ (uint8) (v >> 8), (uint8) (v & 0xff) });
        }

        private static void put32(ByteArray b, uint32 v) {
            b.append({ (uint8) (v >> 24), (uint8) (v >> 16), (uint8) (v >> 8), (uint8) v });
        }

        private static uint16 get16(uint8[] d, int p) {
            return (uint16) ((d[p] << 8) | d[p + 1]);
        }

        private string host_name {
            owned get { return instance + ".local"; }
        }

        private string instance_name {
            owned get { return instance + "." + SERVICE; }
        }

        public void query() {
            query_name(SERVICE, TYPE_PTR);
        }

        private void query_name(string name, uint16 type) {
            if (socket == null) return;
            var b = new ByteArray();
            put16(b, 0);
            put16(b, 0);
            put16(b, 1);
            put16(b, 0);
            put16(b, 0);
            put16(b, 0);
            DnsName.write(b, name);
            put16(b, type);
            put16(b, 1);
            send(b);
        }

        public void announce() {
            if (socket == null || !announcing) return;
            send(build_answer());
        }

        private void send(ByteArray b) {
            var target = new InetSocketAddress.from_string(GROUP, PORT);
            bool sent = false;
            foreach (string entry in NearbyNetif.list()) {
                string[] f = entry.split("\t");
                try {
                    var s = new Socket(SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                    s.multicast_ttl = 255;
                    s.multicast_loopback = false;
                    s.set_option(1, 15, 1);
                    s.bind(new InetSocketAddress.from_string(f[1], PORT), true);
                    s.send_to(target, b.data);
                    s.close();
                    sent = true;
                } catch (Error e) {
                    debug("mdns: send on %s: %s", f[0], e.message);
                }
            }
            if (sent) return;
            try {
                socket.send_to(target, b.data);
            } catch (Error e) {
                debug("mdns: send: %s", e.message);
            }
        }

        private void record_header(ByteArray b, string name, uint16 type, bool flush, uint32 ttl) {
            DnsName.write(b, name);
            put16(b, type);
            put16(b, flush ? 0x8001 : 0x0001);
            put32(b, ttl);
        }

        private ByteArray build_answer() {
            string[] addresses = {};
            foreach (string entry in NearbyNetif.list()) addresses += entry.split("\t")[1];
            var b = new ByteArray();
            put16(b, 0);
            put16(b, 0x8400);
            put16(b, 0);
            put16(b, 4);
            put16(b, 0);
            put16(b, (uint16) addresses.length);

            record_header(b, SERVICE, TYPE_PTR, false, 4500);
            var ptr = new ByteArray();
            DnsName.write(ptr, instance_name);
            put16(b, (uint16) ptr.len);
            b.append(ptr.data);

            record_header(b, instance_name, TYPE_SRV, true, 120);
            var srv = new ByteArray();
            put16(srv, 0);
            put16(srv, 0);
            put16(srv, (uint16) tcp_port);
            DnsName.write(srv, host_name);
            put16(b, (uint16) srv.len);
            b.append(srv.data);

            record_header(b, instance_name, TYPE_TXT, true, 4500);
            var txt = new ByteArray();
            string[] items = { "id=" + instance, "name=" + device_name, "type=" + device_type, "protocol=%d".printf(Packet.PROTOCOL_VERSION) };
            foreach (string item in items) {
                uint8 len = (uint8) int.min(item.length, 255);
                txt.append({ len });
                txt.append(item.data[0:len]);
            }
            put16(b, (uint16) txt.len);
            b.append(txt.data);

            record_header(b, "_services._dns-sd._udp.local", TYPE_PTR, false, 4500);
            var meta = new ByteArray();
            DnsName.write(meta, SERVICE);
            put16(b, (uint16) meta.len);
            b.append(meta.data);

            foreach (string a in addresses) {
                record_header(b, host_name, TYPE_A, true, 120);
                put16(b, 4);
                var addr = new InetAddress.from_string(a);
                b.append(addr.to_bytes()[0:4]);
            }
            return b;
        }

        private void receive() {
            if (socket == null) return;
            uint8[] buf = new uint8[9000];
            SocketAddress from;
            ssize_t n;
            try {
                n = socket.receive_from(out from, buf);
            } catch (Error e) {
                return;
            }
            if (n < 12) return;
            var sender = from as InetSocketAddress;
            if (sender == null) return;
            parse(buf[0:n], sender.address);
        }

        public bool answers(string name, uint16 qtype) {
            string lname = name.down();
            bool any = qtype == 255;
            if (lname == SERVICE) return any || qtype == TYPE_PTR;
            if (lname == instance_name.down()) return any || qtype == TYPE_SRV || qtype == TYPE_TXT;
            if (lname == host_name.down()) return any || qtype == TYPE_A;
            return false;
        }

        public void parse(uint8[] d, InetAddress sender) {
            if (d.length < 12) return;
            uint16 flags = get16(d, 2);
            int qd = get16(d, 4);
            int an = get16(d, 6) + get16(d, 8) + get16(d, 10);
            int p = 12;
            bool asked = false;
            for (int i = 0; i < qd; i++) {
                string? name = DnsName.read(d, ref p);
                if (name == null || p + 4 > d.length) return;
                uint16 qtype = get16(d, p);
                p += 4;
                if (answers(name, qtype)) asked = true;
            }
            if ((flags & 0x8000) == 0) {
                if (asked) announce();
                return;
            }
            var ptrs = new Gee.HashSet<string>();
            var ports = new Gee.HashMap<string, int>();
            var targets = new Gee.HashMap<string, string>();
            var txts = new Gee.HashMap<string, Gee.HashMap<string, string>>();
            var hosts = new Gee.HashMap<string, string>();
            for (int i = 0; i < an; i++) {
                string? name = DnsName.read(d, ref p);
                if (name == null || p + 10 > d.length) return;
                uint16 type = get16(d, p);
                int rdlen = get16(d, p + 8);
                p += 10;
                if (p + rdlen > d.length) return;
                int rd = p;
                string lname = name.down();
                if (type == TYPE_PTR && lname == SERVICE) {
                    int q = rd;
                    string? target = DnsName.read(d, ref q);
                    if (target != null) ptrs.add(target.down());
                } else if (type == TYPE_SRV && rdlen >= 7) {
                    ports[lname] = get16(d, rd + 4);
                    int q = rd + 6;
                    string? target = DnsName.read(d, ref q);
                    if (target != null) targets[lname] = target.down();
                } else if (type == TYPE_TXT) {
                    var map = new Gee.HashMap<string, string>();
                    int q = rd;
                    while (q < rd + rdlen) {
                        int len = d[q];
                        if (q + 1 + len > rd + rdlen) break;
                        string item = ((string) d[q + 1:q + 1 + len]).make_valid(len);
                        int eq = item.index_of_char('=');
                        if (eq > 0) map[item.substring(0, eq)] = item.substring(eq + 1);
                        q += 1 + len;
                    }
                    txts[lname] = map;
                } else if (type == TYPE_A && rdlen == 4) {
                    hosts[lname] = "%u.%u.%u.%u".printf(d[rd], d[rd + 1], d[rd + 2], d[rd + 3]);
                }
                p += rdlen;
            }
            foreach (string inst in ptrs) {
                if (!ports.has_key(inst) && inst != instance_name.down()) query_name(inst, TYPE_SRV);
            }
            foreach (var entry in ports.entries) {
                string inst = entry.key;
                if (!inst.has_suffix("." + SERVICE)) continue;
                var txt = txts[inst];
                string id = txt != null && txt.has_key("id") ? txt["id"] : inst.substring(0, inst.length - SERVICE.length - 1);
                if (id == instance) continue;
                int protocol = txt != null && txt.has_key("protocol") ? int.parse(txt["protocol"]) : 0;
                InetAddress address = sender;
                string? host = targets[inst];
                if (host != null && hosts.has_key(host)) {
                    var parsed = new InetAddress.from_string(hosts[host]);
                    if (parsed != null) address = parsed;
                }
                found(address, entry.value, id, protocol);
            }
        }
    }
}
