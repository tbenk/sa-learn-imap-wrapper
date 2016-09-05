#!/usr/bin/perl

# copyright: B1 Systems GmbH <info@b1-systems.de>, 2016
# license:   GPLv3+, http://www.gnu.org/licenses/gpl-3.0.html
# author:    Timo Benk <benk@b1-systems.de>

# to create the imap spam learning folders use:
# 
# cat <<EOF | cyradm -u benk imap.myhost.de
# createmailbox INBOX.Learn.Ham
# setacl INBOX.Learn.Ham testuser1 lrswipcda
# subscribe INBOX.Learn.Ham
# createmailbox INBOX.Learn.Spam
# setacl INBOX.Learn.Spam testuser1 lrswipcda
# subscribe INBOX.Learn.Spam
# EOF

# to create the sqlite db use:
#
# sqlite3 /var/spool/amavis/.spamassassin/sa-learn-imap-wrapper.db <<EOF
# CREATE TABLE stats (
#   'date'  INT  NOT NULL,
#   'nham'  INT  NOT NULL,
#   'nspam' INT  NOT NULL
# );
# EOF

use strict;
use warnings;

use POSIX 'strftime';
use File::Temp qw/tempfile tempdir/;
use Mail::IMAPClient;
use File::Basename;
use IO::Socket::SSL;
use Getopt::Long;
use Cwd 'abs_path';
use JSON;
use DBI;

###
# possible configuration file locations
my $CONFIG = [
  '/etc/sa-learn-imap-wrapper/sa-learn-imap-wrapper.json',
  '/etc/opt/sa-learn-imap-wrapper/sa-learn-imap-wrapper.json',
  dirname(abs_path($0)) . '/sa-learn-imap-wrapper.json',
];

###
# defaults
my $config = {

  'dbpath'     => '/var/spool/amavis/.spamassassin',
  'regex-ham'  => '^user\.[^.]*\.Learn.Ham$',
  'regex-spam' => '^user\.[^.]*\.Learn.Spam$',
  'keep'       => '7',
  'flag'       => 'sa-learn-imap-wrapper-processed',
  'debug'      => undef,
  'db' => {
    'dsn' => 'DBI:SQLite:dbname=/var/spool/amavis/.spamassassin/sa-learn-imap-wrapper.db',
    'options' => {
      'RaiseError' => 1 
    },
  },
};

###
# dump a short usage info to stdout.
sub usage {

  print "usage: " . basename($0) . " -u <USER> -p <PASS> -h <HOST> ...\n";
  print "\n";
  print "--username,-u   imap username\n";
  print "--password,-p   imap password\n";
  print "--hostname,-h   imap hostname\n";
  print "--regex-ham     regex for ham folders (default: $config->{'regex-ham'})\n";
  print "--regex-spam    regex for spam folders (default: $config->{'regex-spam'})\n";
  print "--keep <DAYS>   keep messages for DAYS days and delete older messages\n";
  print "--dsn <DSN>     database dsn to save statistics (default: $config->{'db'}->{'dsn'})\n";
  print "--debug         enable debug messages\n";
  print "\n";

  exit 3;
}

###
# parse the commandline.
sub parse_commandline {

  my $_config = shift;

  my $arg_username   = $_config->{'username'};
  my $arg_password   = $_config->{'password'};
  my $arg_hostname   = $_config->{'hostname'};
  my $arg_regex_ham  = $_config->{'regex-ham'};
  my $arg_regex_spam = $_config->{'regex-spam'};
  my $arg_keep       = $_config->{'keep'};
  my $arg_debug      = $_config->{'debug'};
  my $arg_dsn        = $_config->{'db'}->{'dsn'};

  my $ret = GetOptions (
    "username|u=s" => \$arg_username,
    "password|p=s" => \$arg_password,
    "hostname|h=s" => \$arg_hostname,
    "regex-ham=s"  => \$arg_regex_ham,
    "regex-spam=s" => \$arg_regex_spam,
    "dsn=s"        => \$arg_dsn,
    "keep=i"       => \$arg_keep,
    "debug"        => \$arg_debug,
  );

  usage() if (not $ret);

  if (not defined($arg_username)) {

    print "error: parameter --username is mandatory.\n";
    usage();
  }

  if (not defined($arg_password)) {

    print "error: parameter --password is mandatory.\n";
    usage();
  }

  if (not defined($arg_hostname)) {

    print "error: parameter --hostname is mandatory.\n";
    usage();
  }

  $_config->{'username'}    = $arg_username;
  $_config->{'password'}    = $arg_password;
  $_config->{'hostname'}    = $arg_hostname;
  $_config->{'regex-ham'}   = $arg_regex_ham;
  $_config->{'regex-spam'}  = $arg_regex_spam;
  $_config->{'debug'}       = $arg_debug;
  $_config->{'keep'}        = $arg_keep;
  $_config->{'db'}->{'dsn'} = $arg_dsn;
}

###
# disconnect from imap server
sub imap_disconnect {

  my $_imap = shift;

  $_imap->disconnect();
}

###
# connect to imap server
sub imap_connect {

  my $_config = shift;

  my $ssl = IO::Socket::SSL->new ( 
    PeerHost => $_config->{'hostname'},
    PeerPort => "imaps",
    SSL_verify_mode => "SSL_VERIFY_NONE"
  );

  die ("could not connect to imap server $_config->{'hostname'}: $@\n") unless defined $ssl;

  $ssl->autoflush(1);

  my $imap = Mail::IMAPClient->new (
    Socket   => $ssl,
    User     => $_config->{'username'},
    Password => $_config->{'password'},
    Peek     => 1
  );

  die ("could not connect to imap server $_config->{'hostname'}: $@\n") unless defined $imap;

  return $imap;
}

###
# process imap folders
sub process {

  my $_imap = shift;
  my $_config = shift;

  my @folders = $_imap->folders() or die("could not list folders.\n");

  my $nham = 0;
  my $nspam = 0;

  foreach my $folder (@folders) {
  
    if ($folder =~ /$_config->{'regex-ham'}/) {

      if (not $_imap->selectable($folder) or not $_imap->select($folder)) {

        print(STDERR "warning: could not select folder: $folder\n");
        next;
      };

      $nham += process_mails($_imap, $_config, 'ham');
      delete_messages($_imap, $_config);
    } elsif ($folder =~ /$_config->{'regex-spam'}/) {

      if (not $_imap->selectable($folder) or not $_imap->select($folder)) {

        print(STDERR "warning: could not select folder: $folder\n");
        next;
      };

      $nspam += process_mails($_imap, $_config, 'spam');
      delete_messages($_imap, $_config);
    }
  }

  save_statistics($_config, $nham, $nspam) if ($nham or $nspam);

  sa_sync($_config);
}

###
# save spam and ham count for statistics
sub save_statistics {

  my $_config = shift;
  my $_nham = shift;
  my $_nspam = shift;

  my $dbh = DBI->connect (
    $_config->{'db'}->{'dsn'},
    $_config->{'db'}->{'userid'},
    $_config->{'db'}->{'password'},
    $_config->{'db'}->{'options'},
  ) or die $DBI::errstr;

  my $sql = "INSERT
             INTO stats (date, nham, nspam)
             VALUES (" . time() . ", $_nham, $_nspam)";

  $dbh->do($sql) or die $DBI::errstr;

  $dbh->disconnect();
}

###
# process all mails in the selected folder
sub process_mails {

  my $_imap = shift;
  my $_config = shift;
  my $_type = shift;

  my $folder = $_imap->Folder();

  my @mails = $_imap->search('UNDELETED NOT KEYWORD ' . $_config->{'flag'});

  print("debug: '$folder' processing " . scalar(@mails) . " messages.\n") if (defined($_config->{'debug'}));

  my $dir = tempdir(CLEANUP => 1);

  if (@mails) {

    download_mails($_imap, $_config, \@mails, $dir);
    sa_learn($_imap, $_config, $_type, $dir);
  }

  return scalar(@mails);
}

###
# download mails from the selected imap folder
sub download_mails {

  my $_imap = shift;
  my $_config = shift;
  my $_mails = shift;
  my $_dir = shift;

  foreach my $mail (@$_mails) {
  
    $_imap->message_to_file("$_dir/$mail", $mail);
  }

  $_imap->set_flag($_config->{'flag'}, @$_mails);
}

###
# delete mails in the selected imap folder
sub delete_messages {

  my $_imap = shift;
  my $_config = shift;

  my $search = 'UNDELETED KEYWORD ' . $_config->{'flag'};
  if ($_config->{keep} > 0) {

    my $date = time() - ($_config->{'keep'} * 24 * 60 * 60);
    my $sdate = POSIX::strftime('%d-%b-%Y', localtime($date));

    $search .= ' SENTBEFORE ' . $sdate;
  }

  if (my $count = $_imap->delete_message($_imap->search($search))) {

    my $folder = $_imap->Folder();
    print("debug: '$folder' $count messages deleted.\n") if (defined($_config->{'debug'}));
  }
}

###
# learn ham, resp. spam mail from mails in given folder
sub sa_learn {

  my $_imap = shift;
  my $_config = shift;
  my $_type = shift;
  my $_dir = shift;

  open(SALEARN, "/usr/bin/sa-learn --dbpath '$_config->{'dbpath'}' --no-sync --$_type '$_dir/*' 2>&1 |") or die "error: $!\n";
  my @output = <SALEARN>;
  close (SALEARN);

  if (@output)  {

    my $folder = $_imap->Folder();

    print("debug: '$folder' [sa-learn] ") if (defined($_config->{'debug'}));;
    print(join("debug: '$folder' [sa-learn] ", @output)) if (defined($_config->{'debug'}));
  }
}

###
# sync bayes db
sub sa_sync {

  my $_config = shift;

  open(SALEARN, "/usr/bin/sa-learn --sync --dbpath '$_config->{'dbpath'}' |");
  my @output = <SALEARN>;
  close (SALEARN);

  if (@output)  {

    print(STDERR 'debug: [sa-learn] ') if (defined($_config->{'debug'}));;
    print(STDERR join('debug: [sa-learn] ', @output)) if (defined($_config->{'debug'}));
  }
}

###
# read configuration from configuration files
sub read_config {

  my $_config = shift;

  my $file;

  foreach my $entry (@$CONFIG) {

    $file = $entry if (-e $entry);
  }

  return if (not $file);

  my $json;
  {
    local $/;
    open(my $fh, '<', $file) or die("cannot read configuration file '$file'");
    $json = <$fh>;
    close $fh;
  };

  my $config2 = decode_json($json);

  %$_config = (%$_config, %{decode_json($json)});
}

###
# main
sub main {

  eval {

    read_config($config);

    parse_commandline($config);

    my $imap = imap_connect($config);

    process($imap, $config);

    imap_disconnect($imap);
  };
  if ($@) {

    print(STDERR "error: $@");
    exit(1);
  }
}

main();
