namespace Singularity.Nearby {

    public delegate Packet IdentityBuilder();
    public delegate string? TrustLookup(string device_id);
    public delegate bool AcceptPolicy(string device_id);

    public class LanProvider : Object {
        private const int MAX_IDENTITY = 8192;

        public UserConfig config { get; construct; }
        public SystemConfig system { get; construct; }
        public int tcp_port { get; private set; default = 0; }
        public Mdns? mdns { get; private set; default = null; }

        private SocketService tcp;
        private Socket? udp;
        private SocketSource? udp_source;
        private TlsCertificate own;
        private IdentityBuilder identity;
        private TrustLookup trust;
        private AcceptPolicy accept;
        private Gee.HashSet<string> connecting = new Gee.HashSet<string>();
        private Gee.HashMap<string, Link> links = new Gee.HashMap<string, Link>();

        public signal void link_ready(Link link);

        public LanProvider(UserConfig config, SystemConfig system, owned IdentityBuilder identity, owned TrustLookup trust, owned AcceptPolicy accept) throws Error {
            Object(config: config, system: system);
            this.identity = (owned) identity;
            this.trust = (owned) trust;
            this.accept = (owned) accept;
            own = Tls.own_certificate(config);
        }

        public void start() throws Error {
            tcp = new SocketService();
            for (int p = system.tcp_port_min; p <= system.tcp_port_max; p++) {
                try {
                    tcp.add_inet_port((uint16) p, null);
                    tcp_port = p;
                    break;
                } catch (Error e) {
                }
            }
            if (tcp_port == 0) throw new IOError.ADDRESS_IN_USE("no free TCP port between %d and %d", system.tcp_port_min, system.tcp_port_max);
            tcp.incoming.connect((conn) => {
                handle_incoming.begin(conn);
                return true;
            });
            tcp.start();

            try {
                udp = new Socket(SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                udp.broadcast = true;
                udp.bind(new InetSocketAddress(new InetAddress.any(SocketFamily.IPV4), (uint16) system.udp_port), true);
                udp_source = udp.create_source(IOCondition.IN, null);
                udp_source.set_callback((s, c) => {
                    receive_udp();
                    return Source.CONTINUE;
                });
                udp_source.attach(MainContext.get_thread_default());
            } catch (Error e) {
                warning("nearby: UDP port %d: %s", system.udp_port, e.message);
                udp = null;
            }

            if (system.mdns) {
                mdns = new Mdns();
                mdns.instance = config.device_id;
                mdns.device_name = config.device_name;
                mdns.device_type = system.resolved_device_type();
                mdns.tcp_port = tcp_port;
                mdns.found.connect((address, port, id, protocol) => discovered(address, port, id, protocol));
                if (!mdns.start()) mdns = null;
            }
        }

        public void stop() {
            if (tcp != null) tcp.stop();
            if (udp_source != null) udp_source.destroy();
            if (mdns != null) mdns.stop();
        }

        public void set_discoverable(bool on) {
            if (mdns != null) {
                mdns.announcing = on;
                if (on) mdns.announce();
            }
        }

        public void broadcast(bool discoverable, string[] unicast) {
            var packet = identity();
            packet.set_int("tcpPort", tcp_port);
            uint8[] data = packet.serialize().data;
            if (discoverable && system.broadcast) {
                foreach (string entry in NearbyNetif.list()) {
                    string[] f = entry.split("\t");
                    string target = f.length > 2 && f[2] != "" ? f[2] : "255.255.255.255";
                    try {
                        var s = new Socket(SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                        s.broadcast = true;
                        s.bind(new InetSocketAddress.from_string(f[1], 0), false);
                        s.send_to(new InetSocketAddress.from_string(target, (uint16) system.udp_port), data);
                        s.close();
                    } catch (Error e) {
                        debug("nearby: broadcast on %s: %s", f[0], e.message);
                    }
                }
            }
            if (discoverable && mdns != null) {
                mdns.announce();
                mdns.query();
            }
            foreach (string addr in unicast) send_unicast(addr, data);
        }

        private void send_unicast(string addr, uint8[] data) {
            if (udp == null || addr == "") return;
            string host = addr;
            int port = system.udp_port;
            int colon = addr.last_index_of_char(':');
            if (colon > 0 && addr.index_of_char(':') == colon) {
                host = addr.substring(0, colon);
                port = int.parse(addr.substring(colon + 1));
            }
            try {
                var address = new InetAddress.from_string(host);
                if (address == null) {
                    var resolved = Resolver.get_default().lookup_by_name(host, null);
                    if (resolved.length() == 0) return;
                    address = resolved.nth_data(0);
                }
                udp.send_to(new InetSocketAddress(address, (uint16) port), data);
            } catch (Error e) {
                debug("nearby: unicast to %s: %s", addr, e.message);
            }
        }

        private void receive_udp() {
            uint8[] buf = new uint8[MAX_IDENTITY];
            SocketAddress from;
            ssize_t n;
            try {
                n = udp.receive_from(out from, buf);
            } catch (Error e) {
                return;
            }
            var sender = from as InetSocketAddress;
            if (n <= 0 || sender == null) return;
            Packet packet;
            try {
                packet = Packet.parse(((string) buf[0:n]).make_valid(n));
            } catch (PacketError e) {
                return;
            }
            if (packet.packet_type != Packet.IDENTITY) return;
            string? id = packet.get_string("deviceId");
            if (!Packet.valid_device_id(id) || id == config.device_id) return;
            discovered(sender.address, (int) packet.get_int("tcpPort", 0), id, (int) packet.get_int("protocolVersion", 0));
        }

        public void discovered(InetAddress address, int port, string device_id, int protocol) {
            if (protocol < Packet.PROTOCOL_VERSION) {
                debug("nearby: ignoring %s, protocol %d is too old", device_id, protocol);
                return;
            }
            if (port < system.tcp_port_min || port > system.tcp_port_max) return;
            if (!accept(device_id)) return;
            if (connecting.contains(device_id)) return;
            var current = links[device_id];
            if (current != null && current.open) return;
            connect_to.begin(address, port, device_id, protocol);
        }

        private async void connect_to(InetAddress address, int port, string device_id, int protocol) {
            connecting.add(device_id);
            try {
                var client = new SocketClient();
                client.timeout = 10;
                var socket = yield client.connect_async(new InetSocketAddress(address, (uint16) port), null);
                set_keepalive(socket);
                var hello = identity();
                hello.set_string("targetDeviceId", device_id);
                hello.set_int("targetProtocolVersion", protocol);
                hello.set_int("tcpPort", tcp_port);
                size_t written;
                yield socket.output_stream.write_all_async(hello.serialize().data, Priority.DEFAULT, null, out written);
                string? trusted = trust(device_id);
                var tls = yield Tls.handshake(socket, true, own, trusted, null);
                socket.socket.timeout = 0;
                yield finish(tls, address, device_id, protocol);
            } catch (Error e) {
                debug("nearby: connecting to %s failed: %s", device_id, e.message);
            }
            connecting.remove(device_id);
        }

        private async void handle_incoming(SocketConnection socket) {
            string? device_id = null;
            try {
                set_keepalive(socket);
                var remote = socket.get_remote_address() as InetSocketAddress;
                var reader = new DataInputStream(socket.input_stream);
                reader.buffer_size = MAX_IDENTITY;
                var cancel = new Cancellable();
                uint t = Timeout.add_seconds(5, () => {
                    cancel.cancel();
                    return Source.REMOVE;
                });
                size_t len;
                string? line = null;
                try {
                    line = yield reader.read_line_utf8_async(Priority.DEFAULT, cancel, out len);
                } finally {
                    if (!cancel.is_cancelled()) Source.remove(t);
                }
                if (line == null) throw new IOError.CLOSED("no identity");
                var packet = Packet.parse(line);
                if (packet.packet_type != Packet.IDENTITY) throw new IOError.INVALID_DATA("not an identity packet");
                device_id = packet.get_string("deviceId");
                if (!Packet.valid_device_id(device_id) || device_id == config.device_id) throw new IOError.INVALID_DATA("bad device id");
                string? target = packet.get_string("targetDeviceId");
                if (target != null && target != config.device_id) throw new IOError.INVALID_DATA("meant for another device");
                int protocol = (int) packet.get_int("protocolVersion", 0);
                if (protocol < Packet.PROTOCOL_VERSION) throw new IOError.NOT_SUPPORTED("protocol %d is too old", protocol);
                if (!accept(device_id)) throw new IOError.PERMISSION_DENIED("not accepting unknown devices");
                if (reader.get_available() > 0) throw new IOError.INVALID_DATA("data before the TLS handshake");
                string? trusted = trust(device_id);
                var tls = yield Tls.handshake(socket, false, own, trusted, null);
                yield finish(tls, remote.address, device_id, protocol);
            } catch (Error e) {
                debug("nearby: incoming connection%s refused: %s", device_id != null ? " from " + device_id : "", e.message);
                try {
                    socket.close();
                } catch (Error e2) {
                }
            }
        }

        private async void finish(TlsConnection tls, InetAddress address, string device_id, int protocol) throws Error {
            size_t written;
            yield tls.output_stream.write_all_async(identity().serialize().data, Priority.DEFAULT, null, out written);
            var reader = new DataInputStream(tls.input_stream);
            var cancel = new Cancellable();
            uint t = Timeout.add_seconds(5, () => {
                cancel.cancel();
                return Source.REMOVE;
            });
            size_t len;
            string? line = null;
            try {
                line = yield reader.read_line_utf8_async(Priority.DEFAULT, cancel, out len);
            } finally {
                if (!cancel.is_cancelled()) Source.remove(t);
            }
            if (line == null) throw new IOError.CLOSED("no secure identity");
            var secure = Packet.parse(line);
            if (secure.packet_type != Packet.IDENTITY) throw new IOError.INVALID_DATA("not an identity packet");
            if (secure.get_string("deviceId") != device_id) throw new IOError.INVALID_DATA("device id changed during the handshake");
            if ((int) secure.get_int("protocolVersion", 0) != protocol) throw new IOError.INVALID_DATA("protocol changed during the handshake");
            if (Packet.filter_name(secure.get_string("deviceName")) == "") throw new IOError.INVALID_DATA("no device name");
            string cn = NearbyCerts.common_name(tls.peer_certificate.certificate_pem);
            if (cn != device_id) throw new IOError.PERMISSION_DENIED("certificate is for %s", cn);
            var link = new Link(device_id, tls, address, secure);
            links[device_id] = link;
            link.closed.connect(forget_link);
            link.start(reader);
            link_ready(link);
        }

        private void forget_link(Link link) {
            link.closed.disconnect(forget_link);
            if (links[link.device_id] == link) links.unset(link.device_id);
        }

        private static void set_keepalive(SocketConnection conn) {
            conn.socket.keepalive = true;
            try {
                conn.socket.set_option(6, 4, 30);
                conn.socket.set_option(6, 5, 10);
                conn.socket.set_option(6, 6, 3);
            } catch (Error e) {
            }
        }
    }
}
