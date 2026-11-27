#!/usr/local/bin/php
<?php

/*
 * Copyright (C) 2026 KSA Technologies, LLC
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * The OPNsense firmware runs this whenever it rewrites the repository
 * configuration, and the package runs it after install. It turns the
 * packaged sample into the live KSA.conf, following the pattern of the
 * official os-sunnyvalley vendor plugin.
 *
 * The KSA-devel repository (development builds) is off by default so
 * production firewalls only see releases. Creating the marker file below
 * opts in; doing it here means the choice survives firmware rewrites.
 */

$conf = '/usr/local/etc/pkg/repos/KSA.conf';
$devel = '/usr/local/etc/pkg/KSA-devel.enable';

if (!file_exists($conf . '.sample')) {
    exit(0);
}

$contents = file_get_contents($conf . '.sample');

if (file_exists($devel)) {
    $contents = preg_replace('/(KSA-devel:\s*\{.*?enabled:\s*)no\b/s', '${1}yes', $contents);
}

file_put_contents($conf, $contents);
