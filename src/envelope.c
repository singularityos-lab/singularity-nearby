#include "envelope.h"

#include <string.h>
#include <gnutls/gnutls.h>
#include <gnutls/abstract.h>
#include <gnutls/crypto.h>
#include <gnutls/x509.h>

#define MAGIC "SNE1"
#define MAGIC_LEN 4
#define COORD 32
#define POINT (1 + COORD * 2)
#define NONCE 12
#define TAG 16
#define KEY 32

G_DEFINE_QUARK (nearby-envelope-error-quark, nearby_envelope_error)

static gboolean
fail (GError **error, int code, const gchar *what, int ret)
{
  g_set_error (error, NEARBY_ENVELOPE_ERROR, code, "%s: %s", what, ret < 0 ? gnutls_strerror (ret) : "invalid");
  return FALSE;
}

static gboolean
put_coord (guint8 *out, const gnutls_datum_t *d)
{
  const guint8 *p = d->data;
  guint n = d->size;
  while (n > COORD && *p == 0) {
    p++;
    n--;
  }
  if (n > COORD)
    return FALSE;
  memset (out, 0, COORD - n);
  memcpy (out + COORD - n, p, n);
  return TRUE;
}

static gboolean
import_peer (const gchar *cert_pem, gnutls_pubkey_t *out, GError **error)
{
  gnutls_x509_crt_t crt;
  gnutls_datum_t data = { (unsigned char *) cert_pem, strlen (cert_pem) };
  int ret;

  *out = NULL;
  if ((ret = gnutls_x509_crt_init (&crt)) < 0)
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "certificate", ret);
  if ((ret = gnutls_x509_crt_import (crt, &data, GNUTLS_X509_FMT_PEM)) < 0) {
    gnutls_x509_crt_deinit (crt);
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "certificate", ret);
  }
  if ((ret = gnutls_pubkey_init (out)) < 0 || (ret = gnutls_pubkey_import_x509 (*out, crt, 0)) < 0) {
    gnutls_x509_crt_deinit (crt);
    if (*out)
      gnutls_pubkey_deinit (*out);
    *out = NULL;
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "certificate key", ret);
  }
  gnutls_x509_crt_deinit (crt);
  if (gnutls_pubkey_get_pk_algorithm (*out, NULL) != GNUTLS_PK_EC) {
    gnutls_pubkey_deinit (*out);
    *out = NULL;
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "certificate key is not an elliptic curve key", 0);
  }
  return TRUE;
}

static gboolean
import_own (const gchar *key_pem, gnutls_privkey_t *out, GError **error)
{
  gnutls_datum_t data = { (unsigned char *) key_pem, strlen (key_pem) };
  int ret;

  *out = NULL;
  if ((ret = gnutls_privkey_init (out)) < 0 ||
      (ret = gnutls_privkey_import_x509_raw (*out, &data, GNUTLS_X509_FMT_PEM, NULL, 0)) < 0) {
    if (*out)
      gnutls_privkey_deinit (*out);
    *out = NULL;
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "device key", ret);
  }
  return TRUE;
}

static gboolean
derive (gnutls_privkey_t priv, gnutls_pubkey_t pub, const guint8 *point, const gchar *context,
        guint8 key[KEY], GError **error)
{
  gnutls_datum_t secret = { NULL, 0 };
  gnutls_datum_t salt = { (unsigned char *) point, POINT };
  gnutls_datum_t info = { (unsigned char *) context, strlen (context) };
  guint8 prk[32];
  gnutls_datum_t prk_d = { prk, sizeof prk };
  int ret;

  if ((ret = gnutls_privkey_derive_secret (priv, pub, NULL, &secret, 0)) < 0)
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "key agreement", ret);
  ret = gnutls_hkdf_extract (GNUTLS_MAC_SHA256, &secret, &salt, prk);
  gnutls_memset (secret.data, 0, secret.size);
  gnutls_free (secret.data);
  if (ret < 0)
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "key derivation", ret);
  ret = gnutls_hkdf_expand (GNUTLS_MAC_SHA256, &prk_d, &info, key, KEY);
  gnutls_memset (prk, 0, sizeof prk);
  if (ret < 0)
    return fail (error, NEARBY_ENVELOPE_ERROR_KEY, "key derivation", ret);
  return TRUE;
}

static GByteArray *
signed_part (const gchar *context, gint64 timestamp, const guint8 *point, const guint8 *nonce,
             const guint8 *body, gsize body_len)
{
  GByteArray *a = g_byte_array_new ();
  guint32 clen = GUINT32_TO_BE ((guint32) strlen (context));
  gint64 ts = GINT64_TO_BE (timestamp);
  g_byte_array_append (a, (const guint8 *) MAGIC, MAGIC_LEN);
  g_byte_array_append (a, (const guint8 *) &clen, 4);
  g_byte_array_append (a, (const guint8 *) context, strlen (context));
  g_byte_array_append (a, (const guint8 *) &ts, 8);
  g_byte_array_append (a, point, POINT);
  g_byte_array_append (a, nonce, NONCE);
  g_byte_array_append (a, body, body_len);
  return a;
}

GBytes *
nearby_envelope_seal (const gchar *own_key_pem, const gchar *peer_cert_pem, const gchar *context,
                      gint64 timestamp, GBytes *plain, GError **error)
{
  gnutls_privkey_t eph = NULL, own = NULL;
  gnutls_pubkey_t peer = NULL;
  gnutls_datum_t x = { NULL, 0 }, y = { NULL, 0 }, sig = { NULL, 0 };
  gnutls_aead_cipher_hd_t aead = NULL;
  guint8 point[POINT], nonce[NONCE], key[KEY];
  gnutls_datum_t key_d = { key, KEY };
  GByteArray *aad = NULL, *out = NULL;
  gsize plain_len;
  const guint8 *plain_data = g_bytes_get_data (plain, &plain_len);
  guint8 *body = NULL;
  size_t body_len;
  GBytes *result = NULL;
  int ret;

  if (!import_peer (peer_cert_pem, &peer, error) || !import_own (own_key_pem, &own, error))
    goto out;
  if ((ret = gnutls_privkey_init (&eph)) < 0 ||
      (ret = gnutls_privkey_generate2 (eph, GNUTLS_PK_EC, GNUTLS_CURVE_TO_BITS (GNUTLS_ECC_CURVE_SECP256R1), 0, NULL, 0)) < 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_KEY, "ephemeral key", ret);
    goto out;
  }
  if ((ret = gnutls_privkey_export_ecc_raw2 (eph, NULL, &x, &y, NULL, 0)) < 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_KEY, "ephemeral key", ret);
    goto out;
  }
  point[0] = 4;
  if (!put_coord (point + 1, &x) || !put_coord (point + 1 + COORD, &y)) {
    fail (error, NEARBY_ENVELOPE_ERROR_KEY, "ephemeral key", 0);
    goto out;
  }
  if (!derive (eph, peer, point, context, key, error))
    goto out;
  if ((ret = gnutls_rnd (GNUTLS_RND_NONCE, nonce, NONCE)) < 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_CRYPTO, "nonce", ret);
    goto out;
  }
  aad = signed_part (context, timestamp, point, nonce, NULL, 0);
  body_len = plain_len + TAG;
  body = g_malloc (body_len);
  if ((ret = gnutls_aead_cipher_init (&aead, GNUTLS_CIPHER_AES_256_GCM, &key_d)) < 0 ||
      (ret = gnutls_aead_cipher_encrypt (aead, nonce, NONCE, aad->data, aad->len, TAG,
                                         plain_data, plain_len, body, &body_len)) < 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_CRYPTO, "encryption", ret);
    goto out;
  }
  g_byte_array_append (aad, body, body_len);
  {
    gnutls_datum_t data = { aad->data, aad->len };
    if ((ret = gnutls_privkey_sign_data2 (own, GNUTLS_SIGN_ECDSA_SHA256, 0, &data, &sig)) < 0) {
      fail (error, NEARBY_ENVELOPE_ERROR_CRYPTO, "signature", ret);
      goto out;
    }
  }
  {
    guint16 slen = GUINT16_TO_BE ((guint16) sig.size);
    gint64 ts = GINT64_TO_BE (timestamp);
    out = g_byte_array_new ();
    g_byte_array_append (out, (const guint8 *) MAGIC, MAGIC_LEN);
    g_byte_array_append (out, (const guint8 *) &ts, 8);
    g_byte_array_append (out, point, POINT);
    g_byte_array_append (out, nonce, NONCE);
    g_byte_array_append (out, (const guint8 *) &slen, 2);
    g_byte_array_append (out, sig.data, sig.size);
    g_byte_array_append (out, body, body_len);
    result = g_byte_array_free_to_bytes (out);
  }

out:
  gnutls_memset (key, 0, sizeof key);
  if (aead)
    gnutls_aead_cipher_deinit (aead);
  if (aad)
    g_byte_array_unref (aad);
  g_free (body);
  gnutls_free (x.data);
  gnutls_free (y.data);
  gnutls_free (sig.data);
  if (eph)
    gnutls_privkey_deinit (eph);
  if (own)
    gnutls_privkey_deinit (own);
  if (peer)
    gnutls_pubkey_deinit (peer);
  return result;
}

GBytes *
nearby_envelope_open (const gchar *own_key_pem, const gchar *peer_cert_pem, const gchar *context,
                      GBytes *sealed, gint64 *timestamp, GError **error)
{
  gnutls_privkey_t own = NULL;
  gnutls_pubkey_t peer = NULL, eph = NULL;
  gnutls_aead_cipher_hd_t aead = NULL;
  gsize len;
  const guint8 *p = g_bytes_get_data (sealed, &len);
  const guint8 *point, *nonce, *sig, *body;
  guint16 slen;
  gint64 ts;
  gsize body_len, header = MAGIC_LEN + 8 + POINT + NONCE + 2;
  guint8 key[KEY];
  gnutls_datum_t key_d = { key, KEY };
  GByteArray *aad = NULL;
  guint8 *plain = NULL;
  size_t plain_len;
  GBytes *result = NULL;
  int ret;

  if (len < header || memcmp (p, MAGIC, MAGIC_LEN) != 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_FORMAT, "not a sealed package", 0);
    return NULL;
  }
  memcpy (&ts, p + MAGIC_LEN, 8);
  ts = GINT64_FROM_BE (ts);
  point = p + MAGIC_LEN + 8;
  nonce = point + POINT;
  memcpy (&slen, nonce + NONCE, 2);
  slen = GUINT16_FROM_BE (slen);
  if (point[0] != 4 || len < header + slen + TAG) {
    fail (error, NEARBY_ENVELOPE_ERROR_FORMAT, "truncated package", 0);
    return NULL;
  }
  sig = nonce + NONCE + 2;
  body = sig + slen;
  body_len = len - header - slen;

  if (!import_peer (peer_cert_pem, &peer, error) || !import_own (own_key_pem, &own, error))
    goto out;
  aad = signed_part (context, ts, point, nonce, body, body_len);
  {
    gnutls_datum_t data = { aad->data, aad->len };
    gnutls_datum_t sig_d = { (unsigned char *) sig, slen };
    if ((ret = gnutls_pubkey_verify_data2 (peer, GNUTLS_SIGN_ECDSA_SHA256, 0, &data, &sig_d)) < 0) {
      fail (error, NEARBY_ENVELOPE_ERROR_SIGNATURE, "the package was not signed by the paired device", ret);
      goto out;
    }
  }
  {
    gnutls_datum_t x = { (unsigned char *) point + 1, COORD }, y = { (unsigned char *) point + 1 + COORD, COORD };
    if ((ret = gnutls_pubkey_init (&eph)) < 0 ||
        (ret = gnutls_pubkey_import_ecc_raw (eph, GNUTLS_ECC_CURVE_SECP256R1, &x, &y)) < 0) {
      fail (error, NEARBY_ENVELOPE_ERROR_FORMAT, "ephemeral key", ret);
      goto out;
    }
  }
  if (!derive (own, eph, point, context, key, error))
    goto out;
  g_byte_array_set_size (aad, aad->len - body_len);
  plain_len = body_len;
  plain = g_malloc (body_len);
  if ((ret = gnutls_aead_cipher_init (&aead, GNUTLS_CIPHER_AES_256_GCM, &key_d)) < 0 ||
      (ret = gnutls_aead_cipher_decrypt (aead, nonce, NONCE, aad->data, aad->len, TAG,
                                         body, body_len, plain, &plain_len)) < 0) {
    fail (error, NEARBY_ENVELOPE_ERROR_CRYPTO, "the package cannot be opened on this device", ret);
    goto out;
  }
  if (timestamp)
    *timestamp = ts;
  result = g_bytes_new_with_free_func (plain, plain_len, (GDestroyNotify) g_free, plain);
  plain = NULL;

out:
  gnutls_memset (key, 0, sizeof key);
  if (aead)
    gnutls_aead_cipher_deinit (aead);
  if (aad)
    g_byte_array_unref (aad);
  if (plain) {
    gnutls_memset (plain, 0, body_len);
    g_free (plain);
  }
  if (eph)
    gnutls_pubkey_deinit (eph);
  if (own)
    gnutls_privkey_deinit (own);
  if (peer)
    gnutls_pubkey_deinit (peer);
  return result;
}
