package Apache::CIPP_Handler;

$VERSION = "0.07";
$REVISION = q$Revision: 1.14 $;

use strict;

use FileHandle;
use Apache::Constants ':common';
use CIPP;
use Config;
use File::Path;

# this global hash holds the timestamps of the compiled perl
# subroutines for this instance

%Apache::CIPP_Handler::compiled = ();

sub handler {
	my $r = shift;

	# print listing if a directory is requested

	my $filename = $r->filename;
	if ( -d $filename ) {
		if ( not -f "$filename/index.cipp" ) {
			print_directory_listing ($r, $filename);
			return;
		} else {
			$filename = "$filename/index.cipp";
		}
	}

	# check if file exists and is readable for us
	# if not: Server Error
	
	return NOT_FOUND if not -f $filename;
	return FORBIDDEN if not -r $filename;
	
	# handle the request
	
	if ( not $r->header_only ) {
	
		my $request = new Apache::CIPP_Handler ($r);
		if ( not $request->process ) {
			$request->error;
		}
		$request->debug if $r->dir_config ("debug");
	} else {
	
		$r->send_http_header;
	}
	
	return OK;
}

sub print_directory_listing {
	my $r = shift;
	my ($dir) = @_;
	
	$r->content_type ("text/html");
	$r->send_http_header;
	
	$r->print (qq{<A HREF="../">../</A><BR>\n});
	while (<$dir/*>) {
		$_ .= "/" if -d $_;
		s!$dir/!!;
		$r->print (qq{<A HREF="$_">$_</A><BR>\n});
	}
}

sub new {
	my $type = shift;
	my ($r) = @_;
	
	my $filename = $r->filename;
	my $uri = $r->uri;
	
	my $self = {
		r => $r,
		filename => $filename,
		uri => $uri,
		status => {
			pid => $$
		},
		error => undef
	};
	
	$self = bless $self, $type;

	$self->{cache_dir} = $r->dir_config ("cache_dir");
	$self->set_sub_filename;
	$self->set_sub_name;
	$self->{err_filename} = $self->{sub_filename}.".err";
	$self->{dep_filename} = $self->{sub_filename}.".dep";

	return $self;
}
		
	
sub process {
	my $self = shift;
	my $r = $self->{r};
	
	$self->preprocess or return;
	$self->compile or return;
	$self->execute or return;
	
	return 1;
}
		

sub preprocess {
	my $self = shift;

	if ( $self->file_cache_ok ) {
		return not $self->has_cached_error;
	}

	my ($r) = $self->{r};
	my $sub_filename = $self->{sub_filename};
	my $sub_name = $self->{sub_name};
	my $filename = $self->{filename};

	# CIPP Parameter
	my $perl_code = "";
	
	my $source = $filename;
	my $target = \$perl_code;
	my $project_hash = undef;
	
	my $databases = $r->dir_config ("databases");
	my @databases = split (/\s*,\s*/, $databases);
	my $db;
	my $database_hash;
	foreach $db (@databases) {
		$database_hash->{$db} = "CIPP_DB_DBI";
	}
	my $default_db = $r->dir_config ("default_db");

	my $mime_type = "text/html";
	my $call_path = $r->uri;
	my $skip_header_line = undef;
	my $debugging = 0;
	my $result_type = "cipp";
	my $use_strict = 1;
	my $persistent = 0;
	my $apache_mod = $r;

	my $CIPP = new CIPP (
		$source, $target, $project_hash, $database_hash, $mime_type,
		$default_db, $call_path, $skip_header_line, $debugging,
		$result_type, $use_strict, $persistent, $apache_mod, undef
	);
	$CIPP->{print_content_type} = 0;
	
	if ( not $CIPP->Get_Init_Status ) {
		$self->{error} = "cipp\tcan't initialize CIPP preprocessor";
		return;
	}

	$CIPP->Preprocess;

	if ( not $CIPP->Get_Preprocess_Status ) {
		my $aref = $CIPP->Get_Messages;
		$self->{error} = "cipp-syntax\t".join ("\n", @{$aref});
		$self->{cipp_debug_text} = $CIPP->Format_Debugging_Source ();
		return;
	}

	# Wegschreiben
	my $output = new FileHandle;
	open ($output, "> $sub_filename") or die "can't write $sub_filename";
	print $output "# mime-type: $CIPP->{mime_type}\n";
	print $output "sub $sub_name {\nmy (\$cipp_apache_request) = \@_;\n";
	print $output $perl_code;
	print $output "}\n";
	close $output;

	# Cache-Dependency-File updaten
	$self->set_dependency ($CIPP->Get_Used_Macros);

	return 1;
}

sub set_dependency {
	my $self = shift;
	
	my ($href) = @_;
	
	my $dep_filename = $self->{dep_filename};
	my $r = $self->{r};
	
	my @list;
	push @list, $self->{filename};

	if ( defined $href ) {
		my $uri;
		foreach $uri (keys %{$href}) {
			my $subr = $r->lookup_uri($uri);
			push @list, $subr->filename;
		}
	}

	open (DEP, "> $dep_filename") or die "can't write $dep_filename";
	print DEP join ("\t", @list);
	close DEP;
}

sub compile {
	my $self = shift;

	return 1 if $self->sub_cache_ok;

	my $sub_name = $self->{sub_name};
	my $sub_filename = $self->{sub_filename};
	
	my $input = new FileHandle;
	
	open ($input, $sub_filename) or die "can't read $sub_filename";
	my $mime_type = <$input>;
	$mime_type =~ s/^#\s*mime-type:\s*//;
	chop $mime_type;
	my $sub = join ('', <$input>);
	close $input;

	eval $sub;

	if ( $@ ) {
		$self->{error} = "XXcompilation\t$@";
		$Apache::CIPP_Handler::compiled{$sub_name} = undef;
		return;
	}
	
	$Apache::CIPP_Handler::compiled{$sub_name} = time;
	$Apache::CIPP_Handler::mime_type{$sub_name} = $mime_type;
	
	unlink $self->{err_filename};

	return 1;
}

sub execute {
	my $self = shift;

	my $sub_name = $self->{sub_name};
	my $r = $self->{r};
	
	if ( $Apache::CIPP_Handler::mime_type{$sub_name} ne 'cipp/dynamic' ) {
		$CIPP::REVISION =~ /(\d+\.\d+)/;
		my $cipp_revision = $1;
		$Apache::CIPP_Handler::REVISION =~ /(\d+\.\d+)/;
		my $cipp_handler_revision = $1;

		$r->content_type ("text/html");
		$r->send_http_header;
		$r->print ("<!-- generated by CIPP $CIPP::VERSION/$cipp_revision with ".
		   "Apache::CIPP_Handler $Apache::CIPP_Handler::VERSION/$cipp_handler_revision ".
		   "-->\n");
	}
		
	no strict 'refs';
	eval { &$sub_name ($r) };
	
	if ( $@ ) {
		$self->{error} = "runtime\t$@";
		return;
	}

	return 1;
}


sub error {
	my $self = shift;
	
	my $r = $self->{r};
	my $sub_filename = $self->{sub_filename};
	my $err_filename = $self->{err_filename};
	my $error = $self->{error};
	my $uri = $r->uri;

	if ( $error !~  m/^runtime\t/ ) {
		my $output = new FileHandle;
		open ($output, "> $err_filename") or die "can't write $err_filename";
		print $output $error;
		close ($output);
		$r->content_type ("text/html");
		$r->send_http_header;
		$r->print ("<HTML><HEAD><TITLE>Error executing $uri</TITLE></HEAD>\n");
		$r->print ("<BODY BGCOLOR=white>\n");
	}

	my ($type) = split ("\t", $error);
	$error =~ s/^([^\t]+)\t//;
	
	$r->print ("<P>Error executing <B>$uri</B>:\n");
	$r->print ("<DL><DT><B>Type</B>:</DT><DD><TT>$type</TT></DD>\n");
	$r->print ("<P><DT><B>Message</B>:</DT><DD><PRE>$error</PRE></DD></DL>\n");

	if ( $self->{cipp_debug_text} ) {
		$r->print (${$self->{cipp_debug_text}});
	}

	$error =~ s/\n+$//;
	$r->log_error ($error);

	1;	
}

sub debug {
	my $self = shift;
	
	my $r = $self->{r};
	my $sub_name = $self->{sub_name};
	my $sub_filename = $self->{sub_filename};
	
	my ($k, $v);
	my $str = "cache=$sub_filename sub=$sub_name";
	while ( ($k, $v) = each %{$self->{status}} ) {
		$str .= " $k=$v";
	}
	$r->warn ("$str");

	return;
	
	while ( ($k, $v) = each %Apache::CIPP_Handler::sub_cnt ) {
		print STDERR ("$k: $v\n");
	}

	1;
}

# Helper Functions ----------------------------------------------------------------

sub set_sub_filename {
	my $self = shift;
	
	my $r = $self->{r};
	my $filename = $self->{uri};
	my $cache_dir = $self->{cache_dir};
	
	my $dir = $filename;
	$dir =~ s![^/]+$!!;
	$dir = $cache_dir.$dir;
	
	( mkpath ($dir, 0, 0700) or die "can't create $dir" ) if not -d $dir;
	
	$filename =~ s!^/!!;
	$self->{sub_filename} = "$cache_dir/$filename.sub";
	
	return 1;
}

sub set_sub_name {
	my $self = shift;
	
	my $uri = $self->{uri};
	$uri =~ s!^/!!;
	$uri =~ s/\W/_/g;
	
	$self->{sub_name} = "CIPP_Pages::process_$uri";
	
	return 1;
}

sub file_cache_ok {
	my $self = shift;
		
	$self->{status}->{file_cache} = 'dirty';

	my $cache_file = $self->{sub_filename};
	
	if ( -e $cache_file ) {
		my $cache_time = (stat ($cache_file))[9];

		my $dep_filename = $self->{dep_filename};
		open (DEP, $dep_filename) or die "can't read $dep_filename";
		my @list = split ("\t", <DEP>);
		close DEP;

		my $path;
		foreach $path (@list)  {
			my $file_time = (stat ($path))[9];
			return if $file_time > $cache_time;
		}
	} else {
		# check if cache_dir exists and create it if not
		mkdir ($self->{cache_dir},0700)	if not -d $self->{cache_dir};
		return;
	}

	$self->{status}->{file_cache} = 'ok';

	return 1;
}

sub sub_cache_ok {
	my $self = shift;

	$self->{status}->{sub_cache} = 'dirty';

	my $cache_file = $self->{sub_filename};
	my $sub_name = $self->{sub_name};
	
	my $cache_time = (stat ($cache_file))[9];
	my $sub_time = $Apache::CIPP_Handler::compiled{$sub_name};

	if ( not defined $sub_time or $cache_time > $sub_time ) {
		$Apache::CIPP_Handler::sub_cnt{$sub_name} = 0;
		return;
	}

	$self->{status}->{sub_cache} = 'ok';
	
	++$Apache::CIPP_Handler::sub_cnt{$sub_name};
	
	return 1;
}

sub has_cached_error {
	my $self = shift;
	
	my $err_filename = $self->{err_filename};
	
	if ( -e $err_filename ) {
		my $input = new FileHandle;
		open ($input, $err_filename) or
			die "can't read $err_filename";
		$self->{error} = join ('', <$input>);
		close $input;

		$self->{status}->{cached_error} = 1;
		
		return 1;
	}

	return;
}

1;
__END__

=head1 NAME

Apache::CIPP_Handler - Apache Request Module to handle CIPP embedded HTML Pages

=head1 SYNOPSIS

  <Location /CIPP>
  
  SetHandler "perl-script"
  PerlHandler Apache::CIPP_Handler

  # directory for caching of preprocessed CIPP programs
  PerlSetVar 	cache_dir	/tmp/cipp_cache

  # debugging infos to error log?
  PerlSetVar	debug		1

  # used databases
  PerlSetVar	databases	zyn, foo

  # default database
  PerlSetVar	default_db	zyn

  # configuration for the database named 'zyn'
  PerlSetVar	db_zyn_data_source      dbi:mysql:zyn
  PerlSetVar	db_zyn_user             my_username1
  PerlSetVar	db_zyn_password         my_password1
  PerlSetVar	db_zyn_auto_commit      1

  # configuration for the database named 'foo'
  PerlSetVar	db_foo_data_source      dbi:Oracle:foo
  PerlSetVar	db_foo_user             my_username2
  PerlSetVar	db_foo_password         my_password2
  PerlSetVar	db_foo_auto_commit      0

  </Location>

=head1 DESCRIPTION

This module works as a request handler for the Apache webserver.
It uses the functionality given by the mod_perl Apache module.
It allows you to use CIPP embedded HTML pages in your webserver
environment.

So you need the CIPP module package (available on CPAN) to use
Apache::CIPP_Handler.

CIPP is a HTML embedding, perl based programming languge, with powerful
web and database capabilities. See the CIPP module and its PDF documentation
for further details.

There are more hints about configuring Apache to work with CIPP in the PDF
documentation of the CIPP module (in german language only).

=head1 AUTHOR

Jörn Reder, joern@dimedis.de

=head1 COPYRIGHT

Copyright 1998-1999 dimedis GmbH, All Rights Reserved

This library ist free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

perl(1), CIPP(3pm)
