#!/usr/bin/perl -W

#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|

# Bandersnatch - A jabber logger and statistics reporter
#
# Bandersnatch is an external Jabber (www.jabber.org) component that logs
# all messages sent to it into a DBI-compatible database. It has a rudimentary
# jabber interface. (Sending a jabber message to the component will ellicit your
# current stats).
#
# Bandersnatch's real usefulness is in it's PHP-based web frontend. From that
# interface it's possible to view remote vs. local usage, individual tranport
# usage, etc. FIXME

###############################################################################
#               Bandersnatch - Jabber logger and statistics reporter          #
#          Copyright (C) 2003, David Young <davidy@funkypenguin.co.za>        #
#                                                                             #
#  This program is free software; you can redistribute it and/or modify it    #
#  under the terms of the GNU General Public License as published by the Free #
#  Software Foundation; either version 2 of the License, or (at your option)  #
#  any later version.                                                         #
#                                                                             #
#  This program is distributed in the hope that it will be useful, but        #
#  WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY #
#  or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License   #
#  for more details.                                                          #
#                                                                             #
#  You should have received a copy of the GNU General Public License along    #
#  with this program; if not, write to the Free Software Foundation, Inc.,    #
# 	59 Temple Place, Suite 330, Boston, MA 02111-1307 USA                 #
#                                                                             #
###############################################################################
my $VERSION = "0.4";

# +----------------------------------------------------------------------------+
# | Declare Global Variables                                                   |
# +----------------------------------------------------------------------------+
my %config;
my $prevmessage = ""; # for catching duplicate messages
my @routes;
my $dbh;
my $timer;
my $status;


# Clean path whenever you use taint checks (Make %ENV safer)
$ENV{'PATH'} = "";
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

# Set up vars
my $config_file = $ARGV[0];
my $configdir = ".";
my $config;

# Check user input
if(defined $config_file)
{
  # Untaint by stripping any bad characters, see "perlsec" man page.
  $config_file =~ /^([-\w.\/]+)$/ or die "Bad characters found\n\n";
  $config_file = $1;
}

else
{
  $config_file = "$configdir/config.xml";
}


# +----------------------------------------------------------------------------+
# | Load Modules                                                               |
# +----------------------------------------------------------------------------+
use strict;
use Net::Jabber qw(Component);
use XML::Stream qw(Tree);
use DBI;
use Getopt::Long;

# +----------------------------------------------------------------------------+
# | Load Command Line Arguments                                                |
# +----------------------------------------------------------------------------+
#my %optctl = ();
#$optctl{config} = "/opt/jabberd/bandersnatch/config.xml";  #FIXME - remember to disable this
#&GetOptions(\%optctl, "config=s");

# +----------------------------------------------------------------------------+
# | Load Configuration                                                         |
# +----------------------------------------------------------------------------+
&loadConfig();

# +----------------------------------------------------------------------------+
# | Initialize Debug System                                                    |
# +----------------------------------------------------------------------------+
my $debug = new Net::Jabber::Debug
  (
    level => $config{debug}->{level},
    header => "Bandersnatch",
    time => 1,
    file => $config{debug}->{file}
  );

# +----------------------------------------------------------------------------+
# | Declare Signal Intercepts                                                  |
# +----------------------------------------------------------------------------+
# | Configure a subroutine to be called when a HUP, KILL, TERM, or INT signal  |
# | is received so that we may shut things down gracefully.                    |
# +----------------------------------------------------------------------------+
$SIG{HUP} = \&Shutdown;
$SIG{KILL} = \&Shutdown;
$SIG{TERM} = \&Shutdown;
$SIG{INT} = \&Shutdown;

# +----------------------------------------------------------------------------+
# | Create Client                                                              |
# +----------------------------------------------------------------------------+
my $component = new Net::Jabber::Client(debuglevel=>$config{debug}->{level});

$component->SetCallBacks
  (
    message => \&messageCB,
    presence => \&presenceCB,
    receive => \&receiveCB,
    iq => \&iqCB,
    onauth => \&onauthCB
  );

# +----------------------------------------------------------------------------+
# | Connect to Jabber Server                                                   |
# +----------------------------------------------------------------------------+
if (!connectJabber())
{
  $debug->Log0("(ERROR) Unable to connect to Jabber server ($config{server}->{hostname}) ...");
  $debug->Log0("        (".$component->GetErrorCode(),")");
  exit(0);
}

#$debug->Log0("Connected to Jabber server ($config{server}->{hostname}) ...");

# +----------------------------------------------------------------------------+
# | Connect to Database Server                                                 |
# +----------------------------------------------------------------------------+
if (!connectDatabase())
{
  $debug->Log0("(ERROR) Unable to connect to MySQL database (".$config{mysql}->{server}."@".$config{mysql}->{server}.")");
  exit(0);
}

$debug->Log0("Connected to MySQL database (".$config{mysql}->{dbname}."@".$config{mysql}->{server}.") ...");


# +----------------------------------------------------------------------------+
# | Flush user table. We don't know how long we've been offline, so set all user
# | records to "offline"
# +----------------------------------------------------------------------------+
flush_user_table();


if (($config{server}->{connectiontype} eq "tcpip") || ($config{server}->{connectiontype} eq "accept"))
{
       $status = $component->Execute(hostname      => $config{server}->{hostname},
 					port       => $config{server}->{port},
                                    password       => $config{server}->{secret},
                                    username 	   => $config{component}->{name});
  }


$debug->Log0("(ERROR) Exiting ...");
exit(0);

# +----------------------------------------------------------------------------+
# | Load Configuration Settings                                                |
# +----------------------------------------------------------------------------+
sub loadConfig
{
  my $parser = new XML::Stream::Parser(style=>"Tree");
  my @tree = $parser->parsefile($config_file);

# +------------------------------------------------------------------------+
# | Jabber Server Settings                                                 |
# +------------------------------------------------------------------------+
  my @serverTree = &XML::Stream::GetXMLData("tree", $tree[0], "server", "", "");
  $config{server}->{hostname} = &XML::Stream::GetXMLData("value", \@serverTree, "hostname", "", "");
  $config{server}->{port} = &XML::Stream::GetXMLData("value", \@serverTree, "port", "", "");
  $config{server}->{secret} = &XML::Stream::GetXMLData("value", \@serverTree, "secret", "", "");
  $config{server}->{connectiontype} = &XML::Stream::GetXMLData("value", \@serverTree, "connectiontype", "", "");
  $config{server}->{connectiontype} = "tcpip" if ($config{server}->{connectiontype} eq "");

# +------------------------------------------------------------------------+
# | Component Settings                                                     |
# +------------------------------------------------------------------------+
  my @componentTree = &XML::Stream::GetXMLData("tree", $tree[0], "component", "", "");
  $config{component}->{name} = &XML::Stream::GetXMLData("value", \@componentTree, "name", "", "");

# +------------------------------------------------------------------------+
# | Database Settings                                                      |
# +------------------------------------------------------------------------+
  my @mysqlTree = &XML::Stream::GetXMLData("tree", $tree[0], "mysql", "", "");
  $config{mysql}->{server} = &XML::Stream::GetXMLData("value", \@mysqlTree, "server", "", "");
  $config{mysql}->{dbname} = &XML::Stream::GetXMLData("value", \@mysqlTree, "dbname", "", "");
  $config{mysql}->{username} = &XML::Stream::GetXMLData("value", \@mysqlTree, "username", "", "");
  $config{mysql}->{password} = &XML::Stream::GetXMLData("value", \@mysqlTree, "password", "", "");

# +------------------------------------------------------------------------+
# | Debug Settings                                                         |
# +------------------------------------------------------------------------+
  my @debugTree = &XML::Stream::GetXMLData("tree", $tree[0], "debug", "", "");
  $config{debug}->{level} = &XML::Stream::GetXMLData("value", \@debugTree, "level", "", "");
  $config{debug}->{file} = &XML::Stream::GetXMLData("value", \@debugTree, "file", "", "");

# +------------------------------------------------------------------------+
# | Site Settings                                                         |
# +------------------------------------------------------------------------+
  my @siteTree = &XML::Stream::GetXMLData("tree", $tree[0], "site", "", "");
  $config{site}->{local_server} = &XML::Stream::GetXMLData("value", \@siteTree, "local_server", "", "");
  $config{site}->{privacy} = &XML::Stream::GetXMLData("value", \@siteTree, "privacy", "", "");
  $config{site}->{aggressive_presence} = &XML::Stream::GetXMLData("value", \@siteTree, "aggressive_presence", "", "");
  my @admin_jids = &XML::Stream::GetXMLData("value array", \@siteTree, "admin_jids", "", "");
  $config{site}->{admin_jids} = \@admin_jids;
  my @confidential_jids = &XML::Stream::GetXMLData("value array", \@siteTree, "confidential_jids", "", "");
  $config{site}->{confidential_jids} = \@confidential_jids;
  my @ignore_jids = &XML::Stream::GetXMLData("value array", \@siteTree, "ignore_jids", "", "");
  my @local_domains = &XML::Stream::GetXMLData("value array", \@siteTree, "local_domains", "", "");

##################################
# check that local_domains contains the value of local_server. If not, put it in :)
##################################
  my $local_server = $config{site}->{local_server};
  my $found_in_array;

  foreach my $domain (@local_domains)
  {

    if ($domain =~ /^$local_server/)
    {
      $found_in_array = 1;
    }
  }

  if (!$found_in_array)
  {
    push(@local_domains,$local_server);
  }
  $config{site}{local_domains} = \@local_domains;

##################################
# check that ignore_jids contains the name of component. If not, put it in :)
##################################
  my $component_name = $config{component}->{name};
  $found_in_array = 0;

  foreach my $jid (@ignore_jids)
  {

    if ($jid =~ /^$component_name/)
    {
    $found_in_array = 1;
    }
  }

  if (!$found_in_array)
  {
    push(@ignore_jids,$component_name);
  }
  $config{site}{ignore_jids} = \@ignore_jids;
  $parser->{HANDLER}->{startDocument} = undef;
  $parser->{HANDLER}->{endDocument}   = undef;
  $parser->{HANDLER}->{startElement}  = undef;
  $parser->{HANDLER}->{endElement}    = undef;
  $parser->{HANDLER}->{characters}    = undef;
}

# +----------------------------------------------------------------------------+
# | Parse <route> XML data                                                     |
# +----------------------------------------------------------------------------+
sub parseroute
{
  my $rawxml = shift;
  my %message;
  my $parser = new XML::Stream::Parser(style=>"Tree");
  my @tree = $parser->parse($rawxml);

# +------------------------------------------------------------------------+
# | Message encapsulated                                                   |
# | in <route> envelope (http://www.jabber.org/protocol/coredata.html)     |
# +------------------------------------------------------------------------+
  my @messageTree = &XML::Stream::GetXMLData("tree", $tree[0], "message", "", "");
  $message{'to'} = &XML::Stream::GetXMLData("value", \@messageTree, "", "to", "");
  $message{'from'} = &XML::Stream::GetXMLData("value", \@messageTree, "", "from", "");
  $message{'id'} = &XML::Stream::GetXMLData("value", \@messageTree, "", "id", "");
  $message{'type'} = &XML::Stream::GetXMLData("value", \@messageTree, "", "type", "");
  $message{'body'} = &XML::Stream::GetXMLData("value", \@messageTree, "body", "", "");		
  $message{'subject'} = &XML::Stream::GetXMLData("value", \@messageTree, "subject", "", "");			
  $message{'thread'} = &XML::Stream::GetXMLData("value", \@messageTree, "thread", "", "");			
  $message{'error'} = &XML::Stream::GetXMLData("value", \@messageTree, "error", "", "");		
  $message{'errorcode'}	= &XML::Stream::GetXMLData("value", \@messageTree, "error", "code", "");
  $parser->{HANDLER}->{startDocument} = undef;
  $parser->{HANDLER}->{endDocument} = undef;
  $parser->{HANDLER}->{startElement} = undef;
  $parser->{HANDLER}->{endElement} = undef;
  $parser->{HANDLER}->{characters} = undef;
  return %message;
}

# +----------------------------------------------------------------------------+
# | Set all users to offline, only called on startup!
# +----------------------------------------------------------------------------+
sub flush_user_table
{
  my $sqlquery = ("UPDATE user SET user_status = 'offline'");
  my $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  $debug->Log1("Startup: Setting all users to offline in user table");
}

#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : determine_presence
# Purpose    : Given type, status, and show, return the "real" presence.
# Parameters : string $type   -> The presence type atribute. Default jabber online type is often blank
#              string $status -> The presence status attribute. More descriptive, but often also blank
#              string $show   -> The presence show attribute. Set by the client, so never 100% reliable
##########################################*/
sub determine_presence
{
  my $type = shift;
  my $status = shift;
  my $show = shift;

  # Mark subscribe / unsub requests as "online"
  if (($type =~ /subscribe$/) || ($type eq "probe"))
  { 
    return "online"; 
  }

  if ((($type eq "unavailable") && (!$status)) || ($status eq "Invisible"))
  {
    return "invisible"; 
  }

  elsif ((!$type) && (!$show))
  {
    return "online";
  }

  elsif (($type eq "unavailable") && ($status))
  {
    return "offline"; 			
  }

  else
  {
    return $show;
  }
}

#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : receiveCB
# Purpose    : Function for the "receive-type" callback. Receives everything in raw XML
# Notes      : Jabber sends data to bandersnatch encased in <route> tags, so Net::Jabber can't
#              readily parse it into an object. So we parse it ourselves.
##########################################*/
sub receiveCB
{
  my $sid = shift;
  my $xmldata = shift;
  my %message = parseroute($xmldata);
  my $sqlquery;
  my $is_local = 0;
  

  if ( $xmldata eq "<bind xmlns='http://jabberd.jabberstudio.org/ns/component/1.0'><log/></bind>" ){
  	$debug->Log0("Binding process finished. Starting to log messages");
	return;
  }

  return if (!$message{'body'}); # Don't log empty messages, or "non-<message>" messages :)

  # Avoid getting "double messages". Rather not modify mod_log.c
  my $currentmessage = $message{'to'}.$message{'from'}.$message{'thread'}.$message{'body'}.$message{'error'};
  return if ($currentmessage eq $prevmessage);
  $prevmessage = $currentmessage;	

  # Ignorable JIDs. (Certain "noisy" chatbot services come to mind!)
  foreach my $ignoreable_jid (@{$config{site}{ignore_jids}})
  {
    if (($message{'to'} =~ /$ignoreable_jid/) || ($message{'from'} =~ /$ignoreable_jid/))
    {
      $debug->Log1("receiveCB: ignoring ($ignoreable_jid)");
      return;
    }
  }

############# Mask confidential messages ########################
  my $to_local;
  my $from_local;

  foreach my $confidential_jid (@{$config{site}{confidential_jids}})
  {
    $to_local = $confidential_jid if ($message{'to'} =~ /$confidential_jid/);
    $from_local = $confidential_jid if ($message{'from'} =~ /$confidential_jid/);
  }

  if (($to_local) && ($from_local))
  {
    $message{'body'} = "Confidential ($from_local --> $to_local)";
  }

############# Mask depending on privacy level ########################
  $to_local = "";
  $from_local = "";

  if ($config{site}{privacy} == 3)
  {
    foreach my $local_domain (@{$config{site}{local_domains}})
    {
      $to_local = $1 if ($message{'to'} =~ /([^@]+)\@$local_domain/);
      $from_local = $1 if ($message{'from'} =~ /([^@]+)\@$local_domain/);
    }
    $message{'to'} =~ s/([^@]+)(\@.*)/privacy-level-3$2/ if (!$to_local);
    $message{'from'} =~ s/([^@]+)(\@.*)/privacy-level-3$2/ if (!$from_local);
    $message{'body'} = "privacy-level-3";
  }

  elsif ($config{site}{privacy} == 2)
  {
    foreach my $local_domain (@{$config{site}{local_domains}})
    {
      $to_local = $1 if ($message{'to'} =~ /([^@]+)\@$local_domain/);
      $from_local = $1 if ($message{'from'} =~ /([^@]+)\@$local_domain/);
    }
    $message{'to'} =~ s/([^@]+)(\@.*)/privacy-level-2$2/ if (!$to_local);
    $message{'from'} =~ s/([^@]+)(\@.*)/privacy-level-2$2/ if (!$from_local);
    $message{'body'} = "privacy-level-2" if ((!$from_local) || (!$to_local));
  }
  elsif ($config{site}{privacy} == 1)
  {
    foreach my $local_domain (@{$config{site}{local_domains}})
    {
      $to_local = $1 if ($message{'to'} =~ /([^@]+)\@$local_domain/);
      $from_local = $1 if ($message{'from'} =~ /([^@]+)\@$local_domain/);
    }
    $message{'to'} =~ s/([^@]+)(\@.*)/privacy-level-1$2/ if (!$to_local);
    $message{'from'} =~ s/([^@]+)(\@.*)/privacy-level-1$2/ if (!$from_local);
  }

############# End Mask depending on privacy level ########################

  # Quote-ify all the variables we're going to be sticking into the database
  $message{'to'} = $dbh->quote($message{'to'});
  $message{'from'} = $dbh->quote($message{'from'});
  $message{'id'} = $dbh->quote($message{'id'});
  $message{'type'} = $dbh->quote($message{'type'});
  $message{'body'} = $dbh->quote($message{'body'});
  $message{'subject'} = $dbh->quote($message{'subject'});
  $message{'thread'} = $dbh->quote($message{'thread'});
  $message{'error'} = $dbh->quote($message{'error'});
  $message{'errorcode'}	= $dbh->quote($message{'errorcode'});		

  $sqlquery = "INSERT INTO message (message_to,message_from,message_id,";
  $sqlquery .= "message_type,message_body,message_subject,message_thread,";
  $sqlquery .= "message_error,message_errorcode) VALUES (";
  $sqlquery .= $message{'to'}. ",";
  $sqlquery .= $message{'from'}. ",";
  $sqlquery .= $message{'id'}. ",";
  $sqlquery .= $message{'type'}. ",";
  $sqlquery .= $message{'body'}. ",";
  $sqlquery .= $message{'subject'}. ",";
  $sqlquery .= $message{'thread'}. ",";
  $sqlquery .= $message{'error'}. ",";
  $sqlquery .= $message{'errorcode'}. ")";

  $debug->Log2("receiveCB: query($sqlquery)");

  my $sth = $dbh->prepare($sqlquery);
  $sth->execute;

  # Update the activity on the users table, if it's SENT by a user on the local SERVER
  my $fromjid;

  if ($message{'from'} =~ /([a-z.]+\@$config{site}->{local_server})\//i )
  {
    $fromjid = $1;
    $sth = $dbh->prepare("SELECT user_status, user_subscribed FROM user WHERE (user_jid = '$fromjid')");
    $sth->execute;
    my ($user_status,$subscribed) = $sth->fetchrow_array();

    if (($user_status) && ($user_status eq "offline"))
    {
      $dbh->do("UPDATE user SET user_status = 'online', user_lastactive = now() WHERE user_jid = '$fromjid'");
    }

    elsif ($user_status)
    {
    $dbh->do("UPDATE user SET user_lastactive = now() WHERE user_jid = '$fromjid'");
    } 

    if ($config{site}{aggressive_presence} eq "1")
    {
      if ($subscribed eq "Y")
      {
        $debug->Log1("Aggressive Presence: $fromjid is subscribed, sending online presence");
        $component->PresenceSend(to=>$fromjid, from=>$config{component}->{name}, type=>"online");
      }

      else
      {
        $debug->Log1("Aggressive Presence: $fromjid is not subscribed, sending subscribe request");
        $component->PresenceSend(to=>$fromjid, type=>"subscribe", from=>$config{component}->{name});
      }
    }
  }
}


#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : createstats
# Purpose    : Creates basic sent-recieve stats for delivery via jabber reply
# Parameters : string $jid -> The JID for whom to create stats
# Notes      : This function calls three "generate_" functions to do the work
##########################################*/
sub create_stats
{
  my $from = shift;
  my $message;
  $message = "\nJabber usage summary for \"$from\"\n\n";
  $message .= generate_message_summary($from,"now()");
  #$message .= generate_presence_history($from);
  $message .= generate_top_list($from,"now()",5);
  $message .= "\n\nRegards,\nBandersnatch\n:dinosaur:";
}			

#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : createstatsadmin
# Purpose    : Creates basic sent-recieve stats for delivery via jabber reply
# Parameters : string $jid -> The JID for whom to create stats
# Notes      : This function calls three "generate_" functions to do the work
##########################################*/
sub create_stats_admin
{
  my $from = shift;
  my $message;
  $message = "\nJabber server statistics for \"".$config{site}->{local_server}. "\"\n\n";
#  $message .= generate_message_summary('',"now()");
#  $message .= generate_presence_history($from);
  $message .= generate_top_list('',"now()",20);
  $message .= "\n\nRegards,\nBandersnatch\n:dinosaur:";
}

#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : messageCB
# Purpose    : Function for message callback
# Parameters : string $sid        -> FIXME - what is this?
#              NJ Object $message -> The message, in a Net::Jabber object
# Notes      : This function is called when a message is sent DIRECTLY to
#              us, NOT as an intercept. i.e. - it was addressed to US.
#              FIXME - Ultimately, admin should get more stats, like users online, top users etc.
##########################################*/
sub messageCB
{
  my $sid = shift;
  my $message = shift;
  my $from = lc($message->GetFrom("jid")->GetJID());
  my $subject = $message->GetSubject();
  my $body = $message->GetBody();
  my $type = $message->GetType();
  my $is_admin = 0;
  my $jog_id;
  my $subscribed;
  $debug->Log1("messageCB: message(",$message->GetXML(),")");

  # Ignorable JIDs. (Certain "noisy" chatbot services come to mind!)
  foreach my $ignoreable_jid (@{$config{site}{ignore_jids}})
  {
    if ($from =~ /$ignoreable_jid/)
    {
      $debug->Log2("messageCB: ignoring ($ignoreable_jid)");
      return;
    }
  }

  # Determine whether the sender is an admin
  foreach my $admin_jid (@{$config{site}{admin_jids}})
  {
    if ($from =~ /$admin_jid/)
    {
      $is_admin = 1;
    }
  }
  
  if ($is_admin == 1)
  {
    $component->MessageSend(to=>$from, from=>$config{component}->{name}, type=>$type, body=>&create_stats_admin($from));
  }

  else
  {
    $component->MessageSend(to=>$from, from=>$config{component}->{name}, type=>$type, body=>&create_stats($from));
  }
}



#__________________________________________
#                                          |
#   |~|_        -- Funky Penguin --        |
#   o-o    Corporate GNU/Linux Solutions   |
#   /V\                                    |
#  // \\                                   |
# /(   )\  ..Work smarter, not harder..    |
#  ^-~-^     [www.funkypenguin.co.za]      |
###########################################|
# Function   : presenceCB
# Purpose    : Function for presence callback
# Parameters : string $sid         -> FIXME - what is this?
#              NJ Object $presence -> The presence message, as a Net::Jabber object
# Notes      : This function is called when we receive a presence message. It
#              was either sent directly to us on purpose, or it was sent via
#              Jabber's <bcc> option.
##########################################*/
sub presenceCB
{
  my $sid = shift;
  my $presence = shift;
  my $sqlquery;
  my $type = $presence->GetType(); 
  my $fromjid = $presence->GetFrom("jid")->GetJID();
  my $from = $presence->GetFrom();	
  my $priority = $presence->GetPriority();
  my $status = $presence->GetStatus();
  my $show = $presence->GetShow();

  $debug->Log1("presenceCB: presence(",$presence->GetXML(),")");

  # Ignorable JIDs. (Certain "noisy" chatbot services come to mind!)
  foreach my $ignoreable_jid (@{$config{site}{ignore_jids}})
  {
    if ($from =~ /$ignoreable_jid/)
    {
      $debug->Log2("presenceCB: ignoring ($ignoreable_jid)");
      return;
    }
  }

  # Log this occurance into the database
  $sqlquery = "INSERT INTO presence (presence_from,presence_type, presence_priority,";
  $sqlquery .= "presence_status,presence_show) VALUES (";
  $sqlquery .= $dbh->quote($from). ",";
  $sqlquery .= $dbh->quote($type). ",";
  $sqlquery .= $dbh->quote($priority). ",";
  $sqlquery .= $dbh->quote($status). ",";
  $sqlquery .= $dbh->quote($show). ")";
  my $sth = $dbh->prepare($sqlquery);
  $sth->execute;

# +------------------------------------------------------------------------+
# | User unsubscribes us from their presence                               |
# +------------------------------------------------------------------------+
  if ($type eq "unsubscribe")
  {
    $debug->Log0("PresenceCB: $from is no longer subscribed to Bandersnatch");
    $dbh->do("UPDATE user SET user_subscribed = 'N' WHERE (user_jid = '$fromjid')");
  }

# +------------------------------------------------------------------------+
# | User accespts our subscription request                                 |
# +------------------------------------------------------------------------+
  elsif ($type eq "subscribed")
  {
    $debug->Log0("PresenceCB: $from is now subscribed to Bandersnatch");
    $component->PresenceSend(to=>$from, from=>$config{component}->{name});
    $dbh->do("UPDATE user SET user_subscribed = 'Y' WHERE (user_jid = '$fromjid')");
  }
	
# +------------------------------------------------------------------------+
# | User has become unavailable                                            |
# +------------------------------------------------------------------------+
  elsif ($type eq "unavailable")
  {
    #do nothing, we'll handle the logging later on
  }

# +------------------------------------------------------------------------+
# | Request subscription from unsubscribed user                            |
# +------------------------------------------------------------------------+
  else
  {
    $debug->Log0("PresenceCB: $from has changed their presence, sending ours...");
    $component->PresenceSend(to=>$from, from=>$config{component}->{name});
  }

# +------------------------------------------------------------------------+
# | Log prescence for local users
# +------------------------------------------------------------------------+
  my $local_server = $config{site}{local_server};

  if (($fromjid =~ /\@$local_server/) && (!($type =~ /subscribe/))) # Don't worry about subscriptions
  {
    my $custom_status;
    # Define a custom status, because jabber's defaults will be null
    if ((($type eq "unavailable") && (!$status)) || (lc($status) eq "invisible"))
    {
      $custom_status = "invisible"; 
    }

    elsif ((!$type) && (!$show))
    {
      $custom_status = "online";
    }

    elsif (($type eq "unavailable") && ($status))
    {
      $custom_status = "offline"; 			
    }

    else
    {
      $custom_status = $show;
    }
		
    my $sth = $dbh->prepare("SELECT count(*) FROM user WHERE (user_jid = '$fromjid')");
    $sth->execute;
    my ($jid_exists) = $sth->fetchrow_array();

    if ($jid_exists > 1)
    {
      die("Something VERY wrong, two jids, both primary keys!");
    }

    elsif ($jid_exists == 0)
    {
      $dbh->do("INSERT INTO user SET user_jid = '$fromjid', user_status='$custom_status'");
    }

    else
    {
      $dbh->do("UPDATE user SET user_status='$custom_status' WHERE user_jid = '$fromjid'");
    }		
  }
}

# +----------------------------------------------------------------------------+
# | Handle <iq/> Packets                                                       |
# +----------------------------------------------------------------------------+
sub iqCB
{
  my $sid = shift;
  my $iq = shift;
  my $query = $iq->GetQuery();
  my $iqReply = $iq->Reply(template=>"component", type=>"result");

  $debug->Log1("iqCB: iq(".$iq->GetXML().")");

  if (!$query)
  {
    return;
  }
	
# +------------------------------------------------------------------------+
# | jabber:iq:version                                                      |
# +------------------------------------------------------------------------+
  if ($query->GetXMLNS() eq "jabber:iq:version")
  {
    my $iqReplyQuery = $iqReply->NewQuery("jabber:iq:version");
    my $os = `uname -s -r`;
    chomp($os);
    $iqReplyQuery->SetVersion(name=>"Bandersnatch", ver=>$VERSION, os=>$os);
  }

# +------------------------------------------------------------------------+
# | jabber:iq:last                                                         |
# +------------------------------------------------------------------------+
  elsif ($query->GetXMLNS() eq "jabber:iq:last")
  {
    my $iqReplyQuery = $iqReply->NewQuery("jabber:iq:last");
    $iqReplyQuery->SetSeconds(timerValue());
  }

# +------------------------------------------------------------------------+
# | Send <iq/> Reply                                                       |
# +------------------------------------------------------------------------+
  if ($iqReply ne "")
  {
    $debug->Log1("iqCB: reply(",$iqReply->GetXML(),")");
    $component->Send($iqReply);
  }

  else
  {
    $debug->Log1("iqCB: no reply");
  }
}

# +----------------------------------------------------------------------------+
# | Connect to Jabber Server                                                   |
# +----------------------------------------------------------------------------+
sub connectJabber
{
  if (($config{server}->{connectiontype} eq "tcpip") || ($config{server}->{connectiontype} eq "accept"))
  {
    $status = $component->Connect
    (
      hostname => $config{server}->{hostname},
      port => $config{server}->{port},
#      secret => $config{server}->{secret},
#      componentname => $config{component}->{name}
    );
	$component->Disconnect();
  }

  if (($config{server}->{connectiontype} eq "stdinout") || ($config{server}->{connectiontype} eq "exec"))
    {
      $status = $component->Connect(connectiontype=>"exec");
    }

  if (!defined($status))
  {
    return 0; 
  }

  timerStart();
  return 1;
}

# +----------------------------------------------------------------------------+
# | Connect to Database Server                                                 |
# +----------------------------------------------------------------------------+
sub connectDatabase
{
  $dbh = DBI->connect("DBI:mysql:database=$config{mysql}->{dbname}:$config{mysql}->{server}",
  $config{mysql}->{username}, $config{mysql}->{password});

  if (!defined($dbh))
  {
    return 0;
  }

  $dbh->trace(2) if (($config{debug}->{level} > 0) && defined($dbh));
  return 1;
}

# +----------------------------------------------------------------------------+
# | Start Uptime Timer                                                         |
# +----------------------------------------------------------------------------+
sub timerStart
{
  $timer = time();
  return 1;
}

# +----------------------------------------------------------------------------+
# | Get Elapsed Time                                                           |
# +----------------------------------------------------------------------------+
sub timerValue
{
  return time() - $timer;
}

# +----------------------------------------------------------------------------+
# | Generate presence history for a given JID                                  |
# +----------------------------------------------------------------------------+
sub generate_presence_history
{
  my $from = shift;
  my $status_lines = "Presence History\n";
  $status_lines .= "--------------\n";
	
  ######## Presence History ###########
  # Work out last status of yesterday
  my $date_condition = "(TO_DAYS(NOW()) - TO_DAYS(presence_timestamp) > 0)";
  my $sqlquery = "SELECT presence_type, presence_status, presence_show FROM presence WHERE presence_from LIKE '%$from%' AND presence_type NOT LIKE 'probe' AND presence_type NOT LIKE '%subscribe' AND $date_condition ORDER BY presence_timestamp DESC LIMIT 0,1";
  my $sth = $dbh->prepare($sqlquery);	 	
  $sth->execute;

  #------- First, work out the most recent presence that's NOT today
  my $yesterday_presence;
  my $status;

  while (my @data = $sth->fetchrow_array())
  {
    my $type = $data[0]; 
    $status = $data[1]; 
    my $show = $data[2]; 
    $yesterday_presence = determine_presence($type,$status,$show);
  }

  if (!$yesterday_presence) { $yesterday_presence = "offline"; } # If no results were returned, he's never logged in

  my %time_array;
  $time_array{"00h00"}->{'presence'} = $yesterday_presence;
  $time_array{"00h00"}->{'status'} = $status;	

  # ------- Get today's presences
  $date_condition = "DATE_FORMAT( presence_timestamp, '%Y%m%d' ) = DATE_FORMAT( now( ) , '%Y%m%d' ) ";
  $sqlquery = "SELECT presence_type, presence_status, presence_show, DATE_FORMAT(presence_timestamp, '%Hh%i') as presence_timestamp_formatted FROM presence WHERE presence_from LIKE '%$from%' AND $date_condition ORDER BY presence_timestamp";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;

  while (my @data = $sth->fetchrow_array())
  {
    my $type = $data[0]; 
    my $status = $data[1]; 
    my $show = $data[2]; 
    my $timestamp = $data[3];
    my $presence;

    if (($type !~ /probe/) && ($type !~ /subscribe/))
    {
      $presence	= determine_presence($type,$status,$show);
      $time_array{$timestamp}->{ 'presence' } = $presence;
      $time_array{$timestamp}->{ 'status' } = $status;
    }								
    # this way, we always get the minute's latest presence!
  }

  #------- Time-travel. Insert the future date into the past array :)
  my $oldpresence;
  my $old_timestamp;
  my $timestamp;
  my %clean_time_array;

  foreach my $timestamp ( sort keys %time_array )
  {
    my $presence  = $time_array{$timestamp}->{ 'presence' };
    my $duplicate;

    if ($presence eq $oldpresence) { $duplicate = 1; }
    $oldpresence = $presence;

    if ($duplicate != 1)
    {
      if ($old_timestamp)
      {
        $clean_time_array{$old_timestamp}->{'future_timestamp'} = $timestamp;
      }

      $clean_time_array{$timestamp}->{'status'}	= $time_array{$timestamp}->{'status'};
      $clean_time_array{$timestamp}->{'presence'} = $time_array{$timestamp}->{'presence'};
      $old_timestamp = $timestamp;
    }
  }
  
  
  #---------- Create the presence list
  $oldpresence = "";

  for $timestamp (sort keys %clean_time_array ) 
  {
    my $presence = $clean_time_array{$timestamp}->{presence};
    my $status = $clean_time_array{$timestamp}->{status};
    my $future_timestamp = $clean_time_array{$timestamp}->{future_timestamp};
    my %nice_names =
    (
      "xa" => "Extended Away",
      "offline"	=> "Offline",
      "online" => "Online",
      "away" => "Away",
      "chat" => "Available For Chat",
      "dnd" => "Do Not Disturb",
      "invisible" => "Invisible"
    );
    my $duplicate;
		
    if(!$future_timestamp)
    { 
      $future_timestamp = "Now"; 
    }

    my $pretty_status;

    if (($status !~ /$presence/i) && ($status !~ /subscri/i) && ($status))
    {
      $pretty_status = "( $status )";
    }

    $status_lines .= "[ $timestamp - $future_timestamp ] ". $nice_names{$presence}. " $pretty_status \n";
  }

  $status_lines .= "\n";
}

#
# Create message stats
#
sub generate_message_summary
{
  my $jid  = shift;
  my $date = shift;
  my $sqlquery;
  my $stats;
  my $date_condition = "DATE_FORMAT( message_timestamp, \'%Y%m%d\' ) = DATE_FORMAT( $date , \'%Y%m%d\' ) ";

  ############ Start sent_local ################
  my $local_domain_condition = "";
 
  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition .= " message_to LIKE '%\@$local_domain%' OR";
  }

  $local_domain_condition = substr($local_domain_condition,0,-3);
  $sqlquery = "SELECT count( * ) FROM message WHERE message_from LIKE '$jid%' AND ($local_domain_condition) AND $date_condition";
  my $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my $sent_local = $sth->fetchrow_array();

  ############# Finished sent_local ############

  ############ Start received_local ################
  $local_domain_condition = "";

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition .= " message_from LIKE '%\@$local_domain%' OR";
  }

  $local_domain_condition = substr($local_domain_condition,0,-3);
  $sqlquery = "SELECT count( * ) FROM message WHERE message_to LIKE '$jid%' AND ($local_domain_condition) AND $date_condition";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my ($received_local) = $sth->fetchrow_array();

  ############ Finished received_local #############

  ############ Start total_local ################
  my $local_domain_condition_to;
  my $local_domain_condition_from;

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition_to   .= " message_to LIKE '%\@$local_domain%' OR";
    $local_domain_condition_from .= " message_from LIKE '%\@$local_domain%' OR";
  }

  $local_domain_condition_to   = substr($local_domain_condition_to,0,-3);
  $local_domain_condition_from = substr($local_domain_condition_from,0,-3);
  $sqlquery = "SELECT count( * ) FROM message WHERE (($local_domain_condition_to) AND ($local_domain_condition_from)) AND $date_condition ";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my ($total_local) = $sth->fetchrow_array();

  ############ Finished total_local ################

  my $percentage_local;

  if ($total_local == 0) { $percentage_local = 0; } # Never divide by zero! :)

  else { $percentage_local = int((($received_local + $sent_local) / $total_local ) * 100); }
	
  ############ Start sent_remote ################
  $local_domain_condition = "";

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition .= " AND message_to NOT LIKE '%\@$local_domain%'";
  }

  $sqlquery = "SELECT count( * ) FROM message WHERE message_from LIKE '$jid%' $local_domain_condition AND $date_condition";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my ($sent_remote) = $sth->fetchrow_array();

  ############ Finished sent_local ################

  ############ Start received_remote ################
  $local_domain_condition = "";

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition .= " AND message_from NOT LIKE '%\@$local_domain%'";
  }

  $sqlquery = "SELECT count( * ) FROM message WHERE message_to LIKE '$jid%' $local_domain_condition AND $date_condition";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my ($received_remote) = $sth->fetchrow_array();

  ############ Finish received_remote ################
	

  ############ Start total_remote ################
  $local_domain_condition_to = "";
  $local_domain_condition_from ="";

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition_to .= " message_to NOT LIKE '%\@$local_domain%' AND";
    $local_domain_condition_from .= " message_from NOT LIKE '%\@$local_domain%' AND";
  }

  $local_domain_condition_to = substr($local_domain_condition_to,0,-4); # trim final AND
  $local_domain_condition_from = substr($local_domain_condition_from,0,-4);
  $sqlquery = "SELECT count( * ) FROM message WHERE (($local_domain_condition_to) OR ($local_domain_condition_from)) AND $date_condition ";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
  my ($total_remote) = $sth->fetchrow_array();

  ############ Finish total_remote ################
 
  my $percentage_remote;

  if ($total_remote == 0) { $percentage_remote = 0; } # Never divide by zero! :)

  else
  {
     $percentage_remote = int((($received_remote + $sent_remote) / $total_remote ) * 100);	
  }
  
  if ($total_local > 0)
  {
    $stats .= "Local messages\n";
    $stats .= "--------------\n";
    $stats .= "Sent:     $sent_local messages\n";
    $stats .= "Received: $received_local messages\n";

    if ($jid)
    {
      $stats .= "Percentage: $percentage_local% of total ($total_local)\n\n";
    }

    else
    {
      $stats .= "Total: $total_local\n\n";
    }
  }

  if ($total_remote > 0)
  {
    $stats .= "Remote messages\n";
    $stats .= "--------------\n";
    $stats .= "Sent:     $sent_remote messages\n";
    $stats .= "Received: $received_remote messages\n";

    if ($jid)
    {
      $stats .= "Percentage: $percentage_remote% of total ($total_remote)\n\n";
    }

    else
    {
      $stats .= "Total: $total_remote\n\n";
    }
  }

  if (($total_remote == 0) && ($total_local == 0))
  {
    $stats = "No messages logged";
  }

  $stats;
}

#
# Create top users
#
sub generate_top_list
{
  my $jid = shift;
  my $date = shift;
  my $amount = shift;
  my $sqlquery;
  my $local_top;
  my $remote_top;
  my $message = "";
  my $date_condition = "DATE_FORMAT( message_timestamp, \'%Y%m%d\' ) = DATE_FORMAT( $date , \'%Y%m%d\' ) ";
	
  ############## Local ################
  # Remote
  # Total messages sent today
  my $local_domain_condition;

  foreach my $local_domain (@{$config{site}{local_domains}}) 
  {
    $local_domain_condition .= " message_to LIKE '%\@$local_domain%' OR";
  }

  $local_domain_condition = substr($local_domain_condition,0,-3);
  $sqlquery = "SELECT count(*) as count, message_to FROM message WHERE message_from LIKE '$jid%' AND ($local_domain_condition) AND $date_condition GROUP BY message_to ORDER BY count DESC LIMIT 0,$amount";
  my $sth = $dbh->prepare($sqlquery);
  $sth->execute;
	
  while (my @data = $sth->fetchrow_array())
  {
    my $count = $data[0]; 
    my $recipient = $data[1];

    if ($recipient =~ /([^\/]+)\// )
    {
      # strip the resource
      $recipient = $1;
    }

    $local_top .= "$recipient (sent $count)\n";
  }	

  if ($local_top)
  {
    $message .= "Top local\n";
    $message .= "---------\n";
    $message .= $local_top;
  }

  ############## Remote ################
  # Total messages sent today
  $local_domain_condition = "";

  foreach my $local_domain (@{$config{site}{local_domains}})
  {
    $local_domain_condition .= " AND message_to NOT LIKE '%\@$local_domain%'";
  }

  $sqlquery = "SELECT count(*) as count, message_to FROM message WHERE message_from LIKE '$jid%' $local_domain_condition AND $date_condition GROUP BY message_to ORDER BY count DESC LIMIT 0,$amount";
  $sth = $dbh->prepare($sqlquery);
  $sth->execute;
	
  while (my @data = $sth->fetchrow_array())
  {
    my $count = $data[0];
    my $recipient = $data[1];

    if ($recipient =~ /([^\/]+)\// )
    {
      # strip the resource
      $recipient = $1;
    }

    $remote_top .= "$recipient (sent $count)\n";
  }

  if ($remote_top)
  {
    $message .= "\nTop remote\n";
    $message .= "------------\n";
    $message .= $remote_top;
  }

  $message;
}

sub onauthCB
{
    $debug->Log0("Connected to Jabber server ($config{server}->{hostname}) ...");
    $debug->Log0("Binding to receive all packets...");
    $component->Send("<bind xmlns='http://jabberd.jabberstudio.org/ns/component/1.0' name=\'$config{component}->{name}\'><log/></bind>");
}

# +----------------------------------------------------------------------------+
# | Handle Shutdown Gracefully                                                 |
# +----------------------------------------------------------------------------+
sub Shutdown
{
  $debug->Log0("Disconnecting from Jabber server ($config{server}->{hostname}) ...");
  $component->Disconnect();
  $debug->Log0("Disconnecting from MySQL server ($config{mysql}->{server}) ...");
  $dbh->disconnect();
  exit(0);
}

