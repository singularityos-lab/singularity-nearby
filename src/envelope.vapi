[CCode (cheader_filename = "envelope.h")]
namespace NearbyEnvelope {
    [CCode (cname = "nearby_envelope_seal")]
    public GLib.Bytes seal(string own_key_pem, string peer_cert_pem, string context, int64 timestamp, GLib.Bytes plain) throws GLib.Error;
    [CCode (cname = "nearby_envelope_open")]
    public GLib.Bytes open(string own_key_pem, string peer_cert_pem, string context, GLib.Bytes sealed, out int64 timestamp) throws GLib.Error;
}
