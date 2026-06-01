<?php

function convertEnvToPost() {
    $_GET = [];
    $QUERY_STRING = getenv('QUERY_STRING');
    if ($QUERY_STRING != '') {
        parse_str(html_entity_decode($QUERY_STRING), $get_array);
        foreach ($get_array as $key => $value) {
            $_GET[urldecode($key)] = urldecode($value);
        }
    }

    $_POST = [];
    $POST_STRING = getenv('POST');
    if ($POST_STRING != '') {
        parse_str(html_entity_decode($POST_STRING), $post_array);
        foreach ($post_array as $key => $value) {
            $_POST[urldecode($key)] = urldecode($value);
        }
    }

    return $_POST;
}

function checkDataDir($pluginPath, $dataFile) {
    $dataDir = $pluginPath . '/data';

    if (!file_exists($dataDir)) {
        mkdir($dataDir, 0755, true);
        chown($dataDir, 'diradmin');
    }

    if (!file_exists($dataFile)) {
        if (!is_writable($dataDir)) {
            return ['success' => false, 'message' => 'Error: Data directory is not writable.'];
        }
        file_put_contents($dataFile, '');
        chmod($dataFile, 0644);
        chown($dataFile, 'diradmin');
    }

    return ['success' => true, 'message' => ''];
}

// Returns ['success' => bool, 'message' => string]
function saveDomain($domainName, $dataFile, $user, $reason = '', $expires = '') {
    if (empty($domainName)) {
        return ['success' => false, 'message' => 'Error: No domain submitted.'];
    }

    $domain = strtolower(trim($domainName));
    $domain = preg_replace('/[^a-z0-9.\-]/', '', $domain);

    if (!preg_match('/^(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $domain)) {
        return ['success' => false, 'message' => 'Error: Invalid domain format. Please enter a valid domain (e.g., example.com).'];
    }

    $expires = trim($expires);
    if ($expires !== '' && !preg_match('/^\d{4}-\d{2}-\d{2}$/', $expires)) {
        return ['success' => false, 'message' => 'Error: Invalid expiry date format. Use YYYY-MM-DD.'];
    }

    $existing = file_exists($dataFile)
        ? file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
        : [];

    foreach ($existing as $line) {
        $parts = explode('|', $line, 3);
        if ($parts[0] === $user && $parts[1] === $domain) {
            return ['success' => false, 'message' => $domain . ' is already in the exclusion list.'];
        }
    }

    $reason   = str_replace(['|', "\n", "\r"], [' ', '', ''], trim($reason));
    $addedAt  = date('Y-m-d');
    $entry    = $user . '|' . $domain . '|' . $reason . '|' . $addedAt . '|' . $expires;

    file_put_contents($dataFile, $entry . PHP_EOL, FILE_APPEND | LOCK_EX);
    return ['success' => true, 'message' => $domain . ' added to the exclusion list.'];
}

// Returns ['success' => bool, 'message' => string]
// $owner is whose entry to delete (admin may pass a different owner than themselves)
function deleteDomain($domainName, $dataFile, $owner) {
    if (empty($domainName)) {
        return ['success' => false, 'message' => 'Error: No domain specified.'];
    }

    $domain = strtolower(trim($domainName));
    $domain = preg_replace('/[^a-z0-9.\-]/', '', $domain);

    if (!file_exists($dataFile)) {
        return ['success' => false, 'message' => 'Error: Exclusion list not found.'];
    }

    $lines    = file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $filtered = array_values(array_filter($lines, function($line) use ($owner, $domain) {
        $parts = explode('|', $line, 3);
        return !($parts[0] === $owner && $parts[1] === $domain);
    }));

    if (count($filtered) === count($lines)) {
        return ['success' => false, 'message' => $domain . ' was not found in the exclusion list.'];
    }

    $content = empty($filtered) ? '' : implode(PHP_EOL, $filtered) . PHP_EOL;
    file_put_contents($dataFile, $content, LOCK_EX);
    return ['success' => true, 'message' => $domain . ' removed from the exclusion list.'];
}

// Parses a single excluded.txt line into an associative array
// Handles both old format (user|domain) and new format (user|domain|reason|added_at|expires)
function parseExclusionEntry($line) {
    $parts = explode('|', $line, 5);
    return [
        'owner'    => $parts[0] ?? '',
        'domain'   => $parts[1] ?? '',
        'reason'   => $parts[2] ?? '',
        'added_at' => $parts[3] ?? '',
        'expires'  => $parts[4] ?? '',
    ];
}

// Returns true if the entry is expired (has a non-empty expires date in the past)
function isExclusionExpired($entry) {
    if (empty($entry['expires'])) {
        return false;
    }
    return strtotime($entry['expires']) < strtotime(date('Y-m-d'));
}

function supportedRegistrars() {
    return ['odr', 'oxxa'];
}

// Parses a tld_exceptions.txt line into ['registrar' => ..., 'tld' => ...]
// Returns null for malformed lines.
function parseTldException($line) {
    $parts = explode('|', $line, 2);
    if (count($parts) !== 2) {
        return null;
    }
    $reg = strtolower(trim($parts[0]));
    $tld = strtolower(trim($parts[1]));
    if ($reg === '' || $tld === '') {
        return null;
    }
    return ['registrar' => $reg, 'tld' => $tld];
}

// Returns ['success' => bool, 'message' => string]
function saveTld($registrar, $tldName, $dataFile) {
    $registrar = strtolower(trim($registrar));
    if (!in_array($registrar, supportedRegistrars(), true)) {
        return ['success' => false, 'message' => 'Error: Unknown registrar.'];
    }

    if (empty($tldName)) {
        return ['success' => false, 'message' => 'Error: No TLD submitted.'];
    }

    $tld = strtolower(trim($tldName));
    $tld = ltrim($tld, '.');
    $tld = preg_replace('/[^a-z0-9.]/', '', $tld);

    if (!preg_match('/^[a-z0-9]+(\.[a-z0-9]+)*$/', $tld) || strlen($tld) < 2) {
        return ['success' => false, 'message' => 'Error: Invalid TLD format. Use e.g. com, co.uk, care.'];
    }

    $existing = file_exists($dataFile)
        ? file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
        : [];

    foreach ($existing as $line) {
        $entry = parseTldException($line);
        if ($entry && $entry['registrar'] === $registrar && $entry['tld'] === $tld) {
            return ['success' => false, 'message' => '.' . $tld . ' is already excluded for ' . strtoupper($registrar) . '.'];
        }
    }

    file_put_contents($dataFile, $registrar . '|' . $tld . PHP_EOL, FILE_APPEND | LOCK_EX);
    return ['success' => true, 'message' => '.' . $tld . ' added to the exception list for ' . strtoupper($registrar) . '.'];
}

// Returns ['success' => bool, 'message' => string]
function deleteTld($registrar, $tldName, $dataFile) {
    $registrar = strtolower(trim($registrar));
    if (!in_array($registrar, supportedRegistrars(), true)) {
        return ['success' => false, 'message' => 'Error: Unknown registrar.'];
    }

    if (empty($tldName)) {
        return ['success' => false, 'message' => 'Error: No TLD specified.'];
    }

    $tld = strtolower(trim($tldName));
    $tld = ltrim($tld, '.');
    $tld = preg_replace('/[^a-z0-9.]/', '', $tld);

    if (!file_exists($dataFile)) {
        return ['success' => false, 'message' => 'Error: TLD exception list not found.'];
    }

    $lines    = file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $filtered = array_values(array_filter($lines, function($line) use ($registrar, $tld) {
        $entry = parseTldException($line);
        if (!$entry) return true;
        return !($entry['registrar'] === $registrar && $entry['tld'] === $tld);
    }));

    if (count($filtered) === count($lines)) {
        return ['success' => false, 'message' => '.' . $tld . ' was not found in the exception list for ' . strtoupper($registrar) . '.'];
    }

    $content = empty($filtered) ? '' : implode(PHP_EOL, $filtered) . PHP_EOL;
    file_put_contents($dataFile, $content, LOCK_EX);
    return ['success' => true, 'message' => '.' . $tld . ' removed from the exception list for ' . strtoupper($registrar) . '.'];
}

// Format an ISO-8601 UTC timestamp ("2026-06-01T14:46:30Z") for display.
// Returns "Jun 1, 2026 14:46 UTC" — keep UTC since the sync script writes UTC.
function formatSyncTime($iso) {
    if (empty($iso)) return '';
    $ts = strtotime($iso);
    if ($ts === false) return htmlspecialchars($iso);
    return gmdate('M j, Y H:i', $ts) . ' UTC';
}

// Builds a redirect URL with a flash message encoded in the query string
function flashRedirectUrl($baseUrl, $result) {
    $ok    = $result['success'] ? '1' : '0';
    $flash = urlencode($result['message']);
    return $baseUrl . '?ok=' . $ok . '&flash=' . $flash;
}

// Returns ['success' => bool, 'message' => string]
// $registrar: 'odr' or 'oxxa'
// $fields: array of POST field name => value (registrar-specific)
function saveCredentials($registrar, $fields, $username, $credsDir) {
    $registrar = strtolower(trim($registrar));
    $allowed   = ['odr', 'oxxa'];
    if (!in_array($registrar, $allowed)) {
        return ['success' => false, 'message' => 'Error: Unknown registrar.'];
    }

    $escaped = function($v) { return str_replace("'", "'\\''", $v); };
    $confFields = [];

    if ($registrar === 'odr') {
        $publicKey  = trim($fields['public_key']  ?? '');
        $privateKey = trim($fields['private_key'] ?? '');
        if (empty($publicKey) || empty($privateKey)) {
            return ['success' => false, 'message' => 'Error: Both ODR public and private key are required.'];
        }
        if (!preg_match('/^[A-Za-z0-9\$\._\-]+$/', $publicKey) || !preg_match('/^[A-Za-z0-9\$\._\-]+$/', $privateKey)) {
            return ['success' => false, 'message' => 'Error: ODR keys may only contain letters, digits, $, ., _ and -.'];
        }
        $confFields = ['ODR_PUBLIC_KEY' => $publicKey, 'ODR_PRIVATE_KEY' => $privateKey];
    } elseif ($registrar === 'oxxa') {
        $oxxaUser = trim($fields['oxxa_user'] ?? '');
        $oxxaPass = trim($fields['oxxa_pass'] ?? '');
        if (empty($oxxaUser) || empty($oxxaPass)) {
            return ['success' => false, 'message' => 'Error: Both OXXA username and password are required.'];
        }
        $confFields = ['OXXA_USER' => $oxxaUser, 'OXXA_PASS' => $oxxaPass];
    }

    if (!is_dir($credsDir)) {
        mkdir($credsDir, 0700, true);
        chown($credsDir, 'diradmin');
    }

    $file    = $credsDir . '/' . $username . '.conf';
    $content = "REGISTRAR='" . $escaped($registrar) . "'\n";
    foreach ($confFields as $key => $value) {
        $content .= $key . "='" . $escaped($value) . "'\n";
    }

    if (file_put_contents($file, $content, LOCK_EX) === false) {
        return ['success' => false, 'message' => 'Error: Could not write credentials file.'];
    }

    chmod($file, 0600);
    chown($file, 'diradmin');
    return ['success' => true, 'message' => 'Credentials saved successfully.'];
}

// Returns key => value pairs from a bash single-quoted credentials conf file
function readCredentials($username, $credsDir) {
    $file = $credsDir . '/' . $username . '.conf';
    if (!file_exists($file)) return [];
    $result = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match("/^(\w+)='(.*)'$/", $line, $m)) {
            $result[$m[1]] = $m[2];
        }
    }
    return $result;
}

// Returns ['success' => bool, 'message' => string]
function deleteCredentials($username, $credsDir) {
    $file = $credsDir . '/' . $username . '.conf';

    if (!file_exists($file)) {
        return ['success' => false, 'message' => 'Error: No credentials file found.'];
    }

    if (!unlink($file)) {
        return ['success' => false, 'message' => 'Error: Could not delete credentials file.'];
    }

    return ['success' => true, 'message' => 'Credentials removed.'];
}

// Returns true if a credentials file exists for the given username
function credentialsExist($username, $credsDir) {
    return file_exists($credsDir . '/' . $username . '.conf');
}
