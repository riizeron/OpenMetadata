# Аутентификация OpenMetadata 1.12.6 через oauth2-proxy и Keycloak

## Вывод

OpenMetadata не поддерживает доверие заголовкам от прокси. `JwtFilter` принимает только
`Authorization: Bearer <JWT>`, проверяет подпись по JWKS и срок действия, `iss` и `aud` не
проверяет. Токен в заголовок подставляет SPA из своего хранилища, без него UI уводит на `/signin`.

Поэтому oauth2-proxy работает только как периметровый шлюз, а OpenMetadata интегрируется с
Keycloak сам. Пользователь проходит два OIDC-редиректа, но пароль вводит один раз: второй редирект
отрабатывает по SSO-сессии Keycloak. С `enableAutoRedirect=true` цепочка проходит без кликов.

## Схема

```
Браузер
  │ https://om.example.ru  — единственный публичный хост, принадлежит oauth2-proxy
  ▼
oauth2-proxy ── OIDC, клиент oauth2-proxy (confidential) ──► Keycloak https://kc.example.ru/realms/datalake
  │ cookie _oauth2_proxy, сессия в Redis                                   ▲
  │ upstream http://openmetadata:8585                                       │ OIDC, клиент openmetadata
  ▼                                                                         │ (public, PKCE, code flow из SPA)
OpenMetadata 1.12.6 ◄── JWKS Keycloak для проверки подписи ID-токенов ──────┘

Airflow / ingestion / CLI / MCP → http://openmetadata:8585 напрямую, минуя oauth2-proxy
```

Режим OpenMetadata: **public** (секрет клиента в OM не требуется). Code flow с PKCE выполняет SPA,
обмен кода на токен идёт из браузера напрямую в Keycloak, обновление токена через скрытый iframe
на `/silent-callback` с откатом на popup.

## Поток входа

1. Браузер открывает `https://om.example.ru`, oauth2-proxy редиректит в Keycloak, пользователь
   вводит пароль. Keycloak возвращает код на `/oauth2/callback`, oauth2-proxy кладёт сессию в Redis.
2. Запрос уходит в OpenMetadata, SPA читает `/api/v1/system/config/auth` и сразу уходит в Keycloak
   с клиентом `openmetadata`.
3. Keycloak по SSO-сессии без формы возвращает код на `https://om.example.ru/callback`, SPA
   обменивает его на ID-токен и хранит его.
4. Каждый API-запрос идёт с `Authorization: Bearer <id_token>`, oauth2-proxy пропускает его без
   изменений, `JwtFilter` проверяет подпись по JWKS Keycloak.

## Keycloak: один realm, два клиента

| Клиент | Тип | Valid redirect URIs | Прочее |
|---|---|---|---|
| `oauth2-proxy` | confidential, Standard flow | `https://om.example.ru/oauth2/callback` | Audience mapper `aud=oauth2-proxy` обязателен; roles mapper для `--allowed-role` |
| `openmetadata` | public (Client authentication Off), Standard flow On, Implicit Off, PKCE S256 | `https://om.example.ru/callback`, `https://om.example.ru/silent-callback` | Web origins `https://om.example.ru`; post logout redirect `https://om.example.ru/signin`; Consent Required Off |

Внутренний адрес OpenMetadata ни в одном redirect URI не участвует.

## oauth2-proxy

```
--provider=keycloak-oidc
--oidc-issuer-url=https://kc.example.ru/realms/datalake
--client-id=oauth2-proxy --client-secret=...
--code-challenge-method=S256
--redirect-url=https://om.example.ru/oauth2/callback
--upstream=http://openmetadata:8585/
--reverse-proxy=true --skip-provider-button=true
--email-domain=*                 # или корпоративный домен
--allowed-role=<realm-role>      # гейтинг на периметре, опционально
--session-store-type=redis --redis-connection-url=redis://...
--cookie-secure=true --cookie-samesite=lax
--cookie-refresh=4m              # меньше Access Token Lifespan в Keycloak
--cookie-expire=8h               # не больше SSO Session Idle
```

Не включать `--pass-authorization-header`, `--set-authorization-header`, `--pass-access-token`:
они перезапишут Bearer-токен SPA и сломают бот-токены и PAT.

## OpenMetadata: переменные окружения

```bash
# Authorizer
AUTHORIZER_CLASS_NAME=org.openmetadata.service.security.DefaultAuthorizer
AUTHORIZER_REQUEST_FILTER=org.openmetadata.service.security.JwtFilter
AUTHORIZER_ADMIN_PRINCIPALS=[ivanov-ii,petrov-pp]     # preferred_username в нижнем регистре
AUTHORIZER_PRINCIPAL_DOMAIN=sber.ru
AUTHORIZER_ENFORCE_PRINCIPAL_DOMAIN=true
AUTHORIZER_USE_ROLES_FROM_PROVIDER=false

# Authentication, public-режим
AUTHENTICATION_PROVIDER=custom-oidc
CUSTOM_OIDC_AUTHENTICATION_PROVIDER_NAME=Keycloak
AUTHENTICATION_CLIENT_TYPE=public
AUTHENTICATION_RESPONSE_TYPE=code
AUTHENTICATION_AUTHORITY=https://kc.example.ru/realms/datalake
AUTHENTICATION_CLIENT_ID=openmetadata
AUTHENTICATION_CALLBACK_URL=https://om.example.ru/callback
AUTHENTICATION_PUBLIC_KEYS=[http://localhost:8585/api/v1/system/config/jwks,https://kc.example.ru/realms/datalake/protocol/openid-connect/certs]
AUTHENTICATION_TOKEN_VALIDATION_ALGORITHM=RS256
AUTHENTICATION_JWT_PRINCIPAL_CLAIMS=[email,preferred_username,sub]
AUTHENTICATION_JWT_PRINCIPAL_CLAIMS_MAPPING=[username:preferred_username,email:email]
AUTHENTICATION_ENABLE_SELF_SIGNUP=true
AUTHENTICATION_ENABLE_AUTO_REDIRECT=true

# Блок OIDC_* в public-режиме не используется, не задавать.

# Собственные JWT OM: боты, PAT. Ключи свои, одинаковые на всех репликах.
RSA_PUBLIC_KEY_FILE_PATH=./conf/public_key.der
RSA_PRIVATE_KEY_FILE_PATH=./conf/private_key.der
JWT_ISSUER=open-metadata.org
JWT_KEY_ID=<уникальный kid>

# Server
SERVER_USE_FORWARDED_HEADERS=true
SERVER_MAX_REQUEST_HEADER_SIZE=16KiB
WEB_CONF_FRAME_OPTION_ENABLED=false                    # или SAMEORIGIN: silent-callback грузится в iframe
```

Первый URL в `AUTHENTICATION_PUBLIC_KEYS` остаётся внутренним: им проверяются токены
ingestion-бота и PAT. Mapping имени пользователя фиксируется до первого входа реальных
пользователей, менять его потом нельзя.

## Ограничения и подводные камни

- **Silent renew** работает без popup, только если Keycloak и OpenMetadata в одном регистрируемом
  домене (например `kc.sber.ru` и `om.sber.ru`). Иначе cookie oauth2-proxy с `SameSite=Lax` не
  уходит в iframe; обход `--cookie-samesite=none` ослабляет защиту от CSRF.
- **Размер заголовков**: cookie прокси, Bearer 2–3 КБ и служебные заголовки не влезают в
  Jetty 8KiB. Нужны Redis-сессия в oauth2-proxy и `SERVER_MAX_REQUEST_HEADER_SIZE=16KiB`.
- **Ingestion и API-клиенты** ходят в OM по внутреннему адресу. Токены OM с issuer
  `open-metadata.org` без discovery и `aud` через `--skip-jwt-bearer-tokens` провалидировать нельзя.
- **Logout** в UI гасит сессии OM и Keycloak; cookie oauth2-proxy живёт до ближайшего
  `cookie-refresh`, после чего refresh падает и пользователь идёт на логин заново.
- **WebSocket** `/api/v1/push/feed/*` авторизуется тем же Bearer и проходит через прокси.
- **Admin-порт 8586** и health-пробы наружу не выводить.

## Альтернатива: confidential-режим

Если секрет клиента в OM всё же можно передать: `AUTHENTICATION_CLIENT_TYPE=confidential`,
клиент `openmetadata` confidential, блок `OIDC_*` с `OIDC_CLIENT_SECRET`, `OIDC_DISCOVERY_URI`,
`OIDC_CALLBACK=https://om.example.ru/callback`, `OIDC_SERVER_URL=https://om.example.ru`,
`FORCE_SECURE_SESSION_COOKIE=true`. Обязательно очистить `OIDC_PROMPT_TYPE=` и `OIDC_MAX_AGE=`:
дефолт `max_age=0` заставляет Keycloak спрашивать пароль повторно и ломает SSO.

Плюсы: refresh через серверную сессию `/api/v1/auth/refresh` без iframe, токен Keycloak не
хранится в браузере. Минусы: серверная сессия Jetty в памяти, нужны sticky sessions при нескольких
репликах; `id_token` проходит в query `/auth/callback`, путь надо исключить из логов прокси
(`--exclude-logging-path=/auth/callback`).

## Проверка

`GET https://om.example.ru/api/v1/system/config/auth` должен вернуть `provider: custom-oidc`,
`clientType: public`, `authority` realm-а и `callbackUrl` с публичным хостом.
