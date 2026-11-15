#!/usr/bin/env bash
# =============================================================================
# populate-volume.sh — скачивание моделей на сетевой том RunPod.
#
# Читает models-manifest.txt (tab-separated: <subdir> <filename> <URL> [<sha256>])
# и кладёт файлы в ${VOL_ROOT}/models/<subdir>/<filename> — это тот же layout,
# который extra_model_paths.yaml отдаёт ComfyUI. Скрипт идемпотентен:
#   - уже существующий файл проверяется по pinned sha256 (или по хешу из
#     состояния тома ${MODELS_DIR}/.populate-state.tsv) и пропускается;
#   - расхождение/битый файл удаляется и скачивается заново;
#   - докачка идёт в <dest>.tmp с `curl --continue-at -`, затем атомарный
#     `mv -f` в целевое имя (повторный job/boot не видит полуфайл);
#   - конкурентные воркеры сериализуются flock'ом на ${VOL_ROOT}/.populate.lock,
#     поэтому холодный старт нескольких воркеров на свежем томе не качает одни
#     и те же файлы параллельно.
#
# Пины обязательны: URL без commit-ревизии (`/resolve/<40-hex>/`) отвергается,
# `main`/`master` запрещены. Если манифест использует placeholder `${VAR}`, он
# раскрывается из окружения, а нераскрытый placeholder — ошибка (лучше упасть с
# понятным текстом, чем молча скачать `main`). Pinned sha256 из 4-й колонки
# проверяется всегда, если задан.
#
# Env:
#   VOL_ROOT     точка монтирования тома      (по умолчанию /runpod-volume)
#   MANIFEST     путь к манифесту моделей     (по умолчанию рядом со скриптом)
#   HF_TOKEN     токен Hugging Face для gated-репозиториев (опционально)
#   HF_ENDPOINT  зеркало Hugging Face         (по умолчанию https://huggingface.co)
#
# Вызывается из docker/entrypoint.sh при VOLUME_AUTOPOPULATE=true; при ошибке
# скачивания entrypoint продолжает старт, а job'ы падают с видимой ошибкой
# отсутствующих моделей (а не «тихо» работают на других весах).
# =============================================================================

set -uo pipefail

VOL_ROOT="${VOL_ROOT:-/runpod-volume}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-${SCRIPT_DIR}/models-manifest.txt}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
MODELS_DIR="${VOL_ROOT}/models"
STATE_FILE="${MODELS_DIR}/.populate-state.tsv"

log() { printf '[populate] %s\n' "$*"; }
warn() { printf '[populate] WARN: %s\n' "$*" >&2; }
die() {
    printf '[populate] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ! -d "${VOL_ROOT}" ]]; then
    log "том ${VOL_ROOT} не смонтирован — скачивание пропущено (attach network volume к endpoint'у)"
    exit 0
fi
if [[ ! -f "${MANIFEST}" ]]; then
    die "нет манифеста ${MANIFEST}: образ собран некорректно (ожидался COPY models-manifest.txt)"
fi

# --- Инструменты -------------------------------------------------------------

#: Команда хеша — массив, чтобы "shasum -a 256" не разбирался на два слова.
SHA_CMD=()
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD=(shasum -a 256)
fi

_sha256() {
    # Печатает хеш; ненулевой код — сбой инструмента/ФС (например, ERANGE на
    # большом файле сетевого тома). Вызывающий обязан отличать это от
    # расхождения хешей: сбой инструмента не повод удалять скачанный файл.
    local out
    out="$("${SHA_CMD[@]}" -- "$1")" || return 1
    printf '%s\n' "${out%% *}"
}

# --- Раскрытие ${VAR} в URL ---------------------------------------------------
# Разрешаем только имена [A-Z0-9_]+ и подставляем значения литерально; eval не
# используется (URL — внешние данные, shell-метасимволы в них не исполняем).
_expand_url() {
    local url="$1" name value
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        value="${!name-}"
        url="${url//\$\{${name}\}/${value}}"
    done < <(printf '%s' "${url}" | grep -oE '\$\{[A-Z0-9_]+\}' | sed -e 's/^\${//' -e 's/}$//' | sort -u)
    printf '%s\n' "${url}"
}

# --- Проверка пина/формата ----------------------------------------------------

_validate_url() {
    local url="$1" where="$2"

    if [[ -z "${url}" ]]; then
        die "${where}: пустой URL"
    fi
    if [[ "${url}" == *'${'* || "${url}" == *'$'* ]]; then
        die "${where}: нераскрытый placeholder в URL (${url}). Задайте переменную ревизии/пути в env — main и «плавающие» ревизии запрещены"
    fi
    if [[ "${url}" =~ /resolve/(main|master)/ ]]; then
        die "${where}: URL указывает на main/master (${url}). Нужен commit-pinned URL: /resolve/<40-hex-commit>/..."
    fi
    if [[ ! "${url}" =~ /resolve/[0-9a-f]{40}/ ]]; then
        die "${where}: URL не запинен на commit (${url}). Ожидался /resolve/<40-hex-commit>/...; pinned-ревизии обязательны"
    fi
}

_validate_sha() {
    local sha="$1" where="$2"
    if [[ -z "${sha}" ]]; then
        warn "${where}: sha256 не задан — проверка будет только по состоянию тома (.populate-state.tsv)"
        return 0
    fi
    if [[ ! "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
        die "${where}: sha256 должен быть 64 lowercase hex, получено '${sha}'"
    fi
}

# --- Состояние тома (pinned-хеши скачанных файлов) ----------------------------

_state_hash() {
    local key="$1"
    [[ -f "${STATE_FILE}" ]] || return 0
    awk -F'\t' -v key="${key}" '$1 == key {print $2; exit}' "${STATE_FILE}"
}

_state_set() {
    local key="$1" sha="$2" size="$3"
    local tmp="${STATE_FILE}.tmp.$$"
    {
        [[ -f "${STATE_FILE}" ]] && awk -F'\t' -v key="${key}" '$1 != key' "${STATE_FILE}"
        printf '%s\t%s\t%s\n' "${key}" "${sha}" "${size}"
    } >"${tmp}" && mv -f "${tmp}" "${STATE_FILE}"
}

# --- Старт -------------------------------------------------------------------

if [[ ${#SHA_CMD[@]} -eq 0 ]]; then
    warn "нет sha256sum/shasum — проверка sha256 невозможна; pinned sha256 в манифесте обязателен, проверьте образ"
fi

total="$(grep -vcE '^[[:space:]]*(#|$)' "${MANIFEST}" || true)"
log "манифест: ${total} файлов; свободно на ${VOL_ROOT}: $(df -h "${VOL_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')"

# Сериализация конкурентных воркеров на общем томе (9 — произвольный fd).
if command -v flock >/dev/null 2>&1; then
    exec 9>"${VOL_ROOT}/.populate.lock"
    flock 9
else
    warn "flock не найден — параллельный populate не сериализуется"
fi

# Layout тома: models/{...}, custom_nodes, encoder-cache создаются заранее.
mkdir -p "${MODELS_DIR}" "${VOL_ROOT}/custom_nodes" "${VOL_ROOT}/encoder-cache"
if [[ ! -f "${STATE_FILE}" ]]; then
    printf '# subdir/filename\tsha256\tsize\n' >"${STATE_FILE}"
fi

done_n=0
failed=0
skipped=0

while IFS=$'\t' read -r sub name url sha extra; do
    sub="${sub%$'\r'}"
    name="${name%$'\r'}"
    url="${url%$'\r'}"
    sha="${sha%$'\r'}"
    extra="${extra%$'\r'}"
    case "${sub}" in ''|\#*) continue ;; esac
    done_n=$((done_n + 1))
    where="строка ${done_n} (${sub}/${name})"

    if [[ -n "${extra}" ]]; then
        die "${where}: лишняя колонка '${extra}'; формат <subdir>\t<filename>\t<URL>[\t<sha256>]"
    fi
    if [[ -z "${name}" || -z "${url}" ]]; then
        warn "${where}: ожидались <subdir> <filename> <URL> [<sha256>]"
        failed=$((failed + 1))
        continue
    fi

    unresolved="$(printf '%s' "${url}" | grep -oE '\$\{[A-Z0-9_]+\}' | sed -e 's/^\${//' -e 's/}$//' | sort -u || true)"
    if [[ -n "${unresolved}" ]]; then
        missing=()
        while IFS= read -r var; do
            [[ -n "${!var-}" ]] || missing+=("${var}")
        done <<<"${unresolved}"
        if [[ ${#missing[@]} -gt 0 ]]; then
            die "${where}: не заданы переменные ревизии/пути: ${missing[*]}. Задайте их в env endpoint'а; main и «плавающие» ревизии запрещены"
        fi
    fi
    url="$(_expand_url "${url}")"
    _validate_url "${url}" "${where}"
    _validate_sha "${sha}" "${where}"

    dest="${MODELS_DIR}/${sub}/${name}"
    key="${sub}/${name}"

    # Зеркало Hugging Face: подменяем только префикс, путь/commit-ревизия
    # сохраняются — пин не теряется.
    if [[ "${HF_ENDPOINT}" != "https://huggingface.co" && "${url}" == https://huggingface.co/* ]]; then
        url="${HF_ENDPOINT%/}/${url#https://huggingface.co/}"
    fi

    mkdir -p "${MODELS_DIR}/${sub}"

    if [[ -s "${dest}" ]]; then
        expected="${sha}"
        if [[ -z "${expected}" ]]; then
            expected="$(_state_hash "${key}")"
        fi
        if [[ -n "${expected}" && ${#SHA_CMD[@]} -gt 0 ]]; then
            if ! actual="$(_sha256 "${dest}")"; then
                warn "[${done_n}/${total}] ${key}: sha256 не посчитан (сбой инструмента/ФС) — файл оставляю без проверки"
                failed=$((failed + 1))
                continue
            fi
            if [[ "${actual}" == "${expected}" ]]; then
                log "[${done_n}/${total}] есть ${key} (sha256 ok)"
                skipped=$((skipped + 1))
                continue
            fi
            warn "[${done_n}/${total}] ${key}: sha256 ${actual} != ожидаемого ${expected} — файл удаляю и качаю заново"
            rm -f "${dest}"
        else
            # Нет пина и нет состояния: фиксируем фактический хеш при первом
            # заполнении тома, дальше проверяем по нему.
            if [[ ${#SHA_CMD[@]} -gt 0 ]]; then
                if ! actual="$(_sha256 "${dest}")"; then
                    warn "[${done_n}/${total}] ${key}: sha256 не посчитан (сбой инструмента/ФС) — файл оставляю без проверки"
                    failed=$((failed + 1))
                    continue
                fi
                size="$(stat -c %s "${dest}" 2>/dev/null || stat -f %z "${dest}" 2>/dev/null || echo 0)"
                _state_set "${key}" "${actual}" "${size}"
                log "[${done_n}/${total}] есть ${key}: sha256 ${actual} зафиксирован в состоянии тома"
                skipped=$((skipped + 1))
                continue
            fi
            log "[${done_n}/${total}] есть ${key}"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    log "[${done_n}/${total}] качаю ${key} ← ${url%%\?*}"
    hdr=()
    if [[ -n "${HF_TOKEN:-}" ]]; then
        hdr=(--header "Authorization: Bearer ${HF_TOKEN}")
    fi

    # --continue-at -: докачиваем .tmp после обрыва, не начиная файл заново.
    if ! curl --fail --location --silent --show-error \
        --retry 5 --retry-delay 10 --continue-at - \
        "${hdr[@]}" --output "${dest}.tmp" "${url}"; then
        code=$?
        warn "${where}: не удалось скачать (curl exit ${code}); частичный файл ${dest}.tmp оставлен для докачки"
        failed=$((failed + 1))
        continue
    fi

    if [[ -n "${sha}" && ${#SHA_CMD[@]} -gt 0 ]]; then
        if ! actual="$(_sha256 "${dest}.tmp")"; then
            warn "${where}: sha256 не посчитан (сбой инструмента/ФС) — .tmp оставлен для повторной проверки, а не удалён"
            failed=$((failed + 1))
            continue
        fi
        if [[ "${actual}" != "${sha}" ]]; then
            warn "${where}: sha256 ${actual} != pinned ${sha} — файл повреждён/подменён, удаляю .tmp"
            rm -f "${dest}.tmp"
            failed=$((failed + 1))
            continue
        fi
    fi

    size="$(stat -c %s "${dest}.tmp" 2>/dev/null || stat -f %z "${dest}.tmp" 2>/dev/null || echo 0)"
    # Атомарная замена в пределах той же ФС: полуфайл никогда не виден как модель.
    if ! mv -f "${dest}.tmp" "${dest}"; then
        warn "${where}: не удалось заменить ${dest} через mv -f"
        failed=$((failed + 1))
        continue
    fi
    if [[ ${#SHA_CMD[@]} -gt 0 ]]; then
        final_sha="${sha}"
        if [[ -z "${final_sha}" ]]; then
            final_sha="$(_sha256 "${dest}" || true)"
        fi
        # Пустой хеш (сбой инструмента) не пишем в состояние: иначе следующий
        # boot считал бы файл «зафиксированным» без проверки.
        if [[ -n "${final_sha}" ]]; then
            _state_set "${key}" "${final_sha}" "${size}"
        fi
    fi
    log "[${done_n}/${total}] готово ${key} (${size} байт)"
done <"${MANIFEST}"

if [[ "${failed}" -gt 0 ]]; then
    warn "не скачано файлов: ${failed} из ${total} (готово уже было: ${skipped}); job'ы на отсутствующих моделях упадут с видимой ошибкой"
    exit 1
fi

log "готово: модели на ${MODELS_DIR} (уже было: ${skipped}); свободно: $(df -h "${VOL_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')"
