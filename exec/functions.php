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
function saveDomain($domainName, $dataFile, $user) {
    if (empty($domainName)) {
        return ['success' => false, 'message' => 'Error: No domain submitted.'];
    }

    $domain = strtolower(trim($domainName));
    $domain = preg_replace('/[^a-z0-9.\-]/', '', $domain);

    if (!preg_match('/^(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $domain)) {
        return ['success' => false, 'message' => 'Error: Invalid domain format. Please enter a valid domain (e.g., example.com).'];
    }

    $existing = file_exists($dataFile)
        ? file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
        : [];
    $entry = $user . '|' . $domain;

    if (in_array($entry, $existing)) {
        return ['success' => false, 'message' => $domain . ' is already in the exclusion list.'];
    }

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
    $entry  = $owner . '|' . $domain;

    if (!file_exists($dataFile)) {
        return ['success' => false, 'message' => 'Error: Exclusion list not found.'];
    }

    $lines    = file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $filtered = array_values(array_filter($lines, fn($line) => $line !== $entry));

    if (count($filtered) === count($lines)) {
        return ['success' => false, 'message' => $domain . ' was not found in the exclusion list.'];
    }

    $content = empty($filtered) ? '' : implode(PHP_EOL, $filtered) . PHP_EOL;
    file_put_contents($dataFile, $content, LOCK_EX);
    return ['success' => true, 'message' => $domain . ' removed from the exclusion list.'];
}

// Returns ['success' => bool, 'message' => string]
function saveTld($tldName, $dataFile) {
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

    if (in_array($tld, $existing)) {
        return ['success' => false, 'message' => '.' . $tld . ' is already in the TLD exception list.'];
    }

    file_put_contents($dataFile, $tld . PHP_EOL, FILE_APPEND | LOCK_EX);
    return ['success' => true, 'message' => '.' . $tld . ' added to the TLD exception list.'];
}

// Returns ['success' => bool, 'message' => string]
function deleteTld($tldName, $dataFile) {
    if (empty($tldName)) {
        return ['success' => false, 'message' => 'Error: No TLD specified.'];
    }

    $tld = strtolower(trim($tldName));
    $tld = preg_replace('/[^a-z0-9.]/', '', $tld);

    if (!file_exists($dataFile)) {
        return ['success' => false, 'message' => 'Error: TLD exception list not found.'];
    }

    $lines    = file($dataFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $filtered = array_values(array_filter($lines, fn($line) => $line !== $tld));

    if (count($filtered) === count($lines)) {
        return ['success' => false, 'message' => '.' . $tld . ' was not found in the TLD exception list.'];
    }

    $content = empty($filtered) ? '' : implode(PHP_EOL, $filtered) . PHP_EOL;
    file_put_contents($dataFile, $content, LOCK_EX);
    return ['success' => true, 'message' => '.' . $tld . ' removed from the TLD exception list.'];
}

// Builds a redirect URL with a flash message encoded in the query string
function flashRedirectUrl($baseUrl, $result) {
    $ok    = $result['success'] ? '1' : '0';
    $flash = urlencode($result['message']);
    return $baseUrl . '?ok=' . $ok . '&flash=' . $flash;
}
