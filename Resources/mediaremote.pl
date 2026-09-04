# Loads ATFMMediaRemote.dylib inside Apple's perl so MediaRemote shares Now Playing info. Usage: perl mediaremote.pl <dylib>
use strict;
use DynaLoader;
$| = 1;
my $path = $ARGV[0] or die "usage: mediaremote.pl <dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0x01) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "atfm_mediaremote_main") or die "symbol missing: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::atfm_main", $sym);
atfm_main();
