#ifndef _M5NSLIBRE_H
#define _M5NSLIBRE_H

#include "M5NSconfig.h"

// Fetches the latest glucose readings from a LibreLinkUp ("LibreView") follower account.
// Mirrors readDexcom(): returns 0 on success, else an error code (also logged via addErrorLog).
int readLibre(tConfig *cfg, struct NSinfo *ns);

// Clears the cached LibreLinkUp auth token, account-id hash and patient id, and the
// bad-credential backoff flag. Call whenever the LibreLinkUp email, password or region changes.
void libreResetSession();

// Region codes for cfg->libre_server (0-11), in index order: AE, AP, AU, CA, DE, EU, EU2,
// FR, JP, US, LA, RU. Used for the web UI region dropdown and to match the "redirect" region
// LibreLinkUp reports when an account was created in a different region than configured.
extern const char* const libreRegionNames[12];

#endif
