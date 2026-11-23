#pragma once

#include <glib.h>

#define NEARBY_ENVELOPE_ERROR (nearby_envelope_error_quark ())

typedef enum {
  NEARBY_ENVELOPE_ERROR_FORMAT,
  NEARBY_ENVELOPE_ERROR_KEY,
  NEARBY_ENVELOPE_ERROR_CRYPTO,
  NEARBY_ENVELOPE_ERROR_SIGNATURE
} NearbyEnvelopeError;

GQuark nearby_envelope_error_quark (void);

GBytes *nearby_envelope_seal (const gchar *own_key_pem, const gchar *peer_cert_pem, const gchar *context,
                              gint64 timestamp, GBytes *plain, GError **error);
GBytes *nearby_envelope_open (const gchar *own_key_pem, const gchar *peer_cert_pem, const gchar *context,
                              GBytes *sealed, gint64 *timestamp, GError **error);
