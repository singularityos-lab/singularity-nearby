namespace Singularity.Nearby {

    public class Tls : Object {
        public static TlsCertificate own_certificate(UserConfig config) throws Error {
            return new TlsCertificate.from_pem(config.certificate_pem + "\n" + config.private_key_pem, -1);
        }

        public static bool same_certificate(TlsCertificate? cert, string pem) {
            if (cert == null || pem == "") return false;
            try {
                return cert.is_same(new TlsCertificate.from_pem(pem, -1));
            } catch (Error e) {
                return false;
            }
        }

        public static async TlsConnection handshake(IOStream base_stream, bool as_server, TlsCertificate own,
                                                   string? trusted_pem, Cancellable? cancellable) throws Error {
            TlsConnection conn;
            if (as_server) {
                var server = TlsServerConnection.new(base_stream, own);
                server.authentication_mode = TlsAuthenticationMode.REQUIRED;
                conn = server;
            } else {
                var client = TlsClientConnection.new(base_stream, null);
                client.certificate = own;
                conn = client;
            }
            conn.accept_certificate.connect((peer, errors) => {
                if (trusted_pem == null) return true;
                return Tls.same_certificate(peer, trusted_pem);
            });
            yield conn.handshake_async(Priority.DEFAULT, cancellable);
            if (conn.peer_certificate == null) throw new IOError.PERMISSION_DENIED("the peer sent no certificate");
            if (trusted_pem != null && !same_certificate(conn.peer_certificate, trusted_pem)) {
                throw new IOError.PERMISSION_DENIED("the peer certificate changed");
            }
            return conn;
        }
    }

    public class Link : Object {
        public string device_id { get; construct; }
        public TlsConnection connection { get; construct; }
        public InetAddress address { get; construct; }
        public Packet identity { get; set; }
        public bool open { get; private set; default = true; }
        public bool relayed { get; set; default = false; }
        public int64 last_activity { get; private set; default = GLib.get_monotonic_time(); }

        private DataInputStream reader;
        private Queue<string> outgoing = new Queue<string>();
        private bool writing = false;
        private Cancellable cancellable = new Cancellable();

        public signal void packet_received(Packet packet);
        public signal void closed();

        public Link(string device_id, TlsConnection connection, InetAddress address, Packet identity) {
            Object(device_id: device_id, connection: connection, address: address);
            this.identity = identity;
        }

        public string peer_certificate_pem {
            owned get { return connection.peer_certificate != null ? connection.peer_certificate.certificate_pem : ""; }
        }

        public void start(DataInputStream? existing = null) {
            reader = existing ?? new DataInputStream(connection.input_stream);
            reader.newline_type = DataStreamNewlineType.LF;
            read_loop.begin();
        }

        private async void read_loop() {
            while (open) {
                string? line = null;
                try {
                    size_t len;
                    line = yield reader.read_line_utf8_async(Priority.DEFAULT, cancellable, out len);
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED)) debug("link %s: %s", device_id, e.message);
                    line = null;
                }
                if (line == null) break;
                last_activity = GLib.get_monotonic_time();
                if (line.strip() == "") continue;
                try {
                    var packet = Packet.parse(line);
                    packet_received(packet);
                } catch (PacketError e) {
                    warning("link %s: dropped a packet: %s", device_id, e.message);
                }
            }
            close();
        }

        public void send(Packet packet) {
            if (!open) return;
            outgoing.push_tail(packet.serialize());
            if (!writing) flush.begin();
        }

        private async void flush() {
            writing = true;
            while (open && !outgoing.is_empty()) {
                string data = outgoing.pop_head();
                try {
                    size_t written;
                    yield connection.output_stream.write_all_async(data.data, Priority.DEFAULT, cancellable, out written);
                } catch (Error e) {
                    debug("link %s: write failed: %s", device_id, e.message);
                    close();
                    break;
                }
            }
            writing = false;
        }

        public void close() {
            if (!open) return;
            open = false;
            cancellable.cancel();
            connection.close_async.begin(Priority.DEFAULT, null);
            closed();
        }
    }

    public class PayloadServer : Object {
        public int port { get; private set; default = 0; }
        private SocketListener listener = new SocketListener();

        public PayloadServer(SystemConfig system) throws Error {
            for (int p = system.transfer_port_min; p <= system.transfer_port_max; p++) {
                try {
                    listener.add_inet_port((uint16) p, null);
                    port = p;
                    return;
                } catch (Error e) {
                }
            }
            throw new IOError.ADDRESS_IN_USE("no free port for the transfer");
        }

        public async void serve(InputStream source, int64 size, TlsCertificate own, string trusted_pem,
                                Cancellable? cancellable, owned ProgressFunc? progress) throws Error {
            uint timeout = Timeout.add_seconds(60, () => {
                listener.close();
                return Source.REMOVE;
            });
            SocketConnection? socket = null;
            try {
                socket = yield listener.accept_async(cancellable, null);
            } finally {
                Source.remove(timeout);
                listener.close();
            }
            if (socket == null) throw new IOError.TIMED_OUT("the other device did not connect");
            var tls = yield Tls.handshake(socket, true, own, trusted_pem, cancellable);
            yield copy(source, tls.output_stream, size, cancellable, (owned) progress);
            yield tls.close_async(Priority.DEFAULT, null);
        }

        public void cancel() {
            listener.close();
        }
    }

    public delegate void ProgressFunc(int64 done, int64 total);

    public static async int64 copy(InputStream from, OutputStream to, int64 size, Cancellable? cancellable, owned ProgressFunc? progress) throws Error {
        uint8[] buffer = new uint8[65536];
        int64 done = 0;
        int64 last_report = 0;
        while (size < 0 || done < size) {
            size_t want = buffer.length;
            if (size >= 0 && size - done < want) want = (size_t) (size - done);
            ssize_t n = yield from.read_async(buffer[0:want], Priority.DEFAULT, cancellable);
            if (n <= 0) break;
            size_t written;
            yield to.write_all_async(buffer[0:n], Priority.DEFAULT, cancellable, out written);
            done += n;
            if (progress != null && (done - last_report > 262144 || done == size)) {
                last_report = done;
                progress(done, size);
            }
        }
        yield to.flush_async(Priority.DEFAULT, cancellable);
        if (size >= 0 && done < size) throw new IOError.PARTIAL_INPUT("the transfer stopped at %s of %s".printf(done.to_string(), size.to_string()));
        return done;
    }

    public static async TlsConnection connect_payload(InetAddress address, int port, TlsCertificate own, string trusted_pem, Cancellable? cancellable) throws Error {
        var client = new SocketClient();
        client.timeout = 15;
        var socket = yield client.connect_async(new InetSocketAddress(address, (uint16) port), cancellable);
        return yield Tls.handshake(socket, false, own, trusted_pem, cancellable);
    }
}
