package DDGC::DB::Result::Token::Domain::Language;
# ABSTRACT: A Token::Domain::Language exist for every language of a token domain

use Moose;
use MooseX::NonMoose;
extends 'DDGC::DB::Base::Result';
use DBIx::Class::Candy;

use File::Spec;
use File::Which;
use IO::All -utf8;
use Path::Class;
use Carp;
use DateTime;
use DateTime::Format::Strptime;
use POSIX qw( floor );

use namespace::autoclean;

table 'token_domain_language';

sub u { 
	my ( $self ) = @_;
	[ 'Translate', 'landing', $self->token_domain->key, $self->language->locale ]
}

sub u_untranslated { 
	my ( $self ) = @_;
	[ 'Translate', 'untranslated', $self->token_domain->key, $self->language->locale ]
}

sub u_unvoted { 
	my ( $self ) = @_;
	[ 'Translate', 'unvoted', $self->token_domain->key, $self->language->locale ]
}

sub u_tokens { 
	my ( $self ) = @_;
	[ 'Translate', 'tokens', $self->token_domain->key, $self->language->locale ]
}

sub u_overview { 
	my ( $self ) = @_;
	[ 'Translate', 'alltokens', $self->token_domain->key, $self->language->locale ]
}

sub u_comments {
	my ( $self ) = @_;
	[ 'Translate', 'localecomments', $self->token_domain->key, $self->language->locale ]
}


column id => {
	data_type => 'bigint',
	is_auto_increment => 1,
};
primary_key 'id';

column language_id => {
	data_type => 'bigint',
	is_nullable => 0,
};

column token_domain_id => {
	data_type => 'bigint',
	is_nullable => 0,
};

column sticky_notes => {
	data_type => 'text',
	is_nullable => 1,
};

column created => {
	data_type => 'timestamp with time zone',
	set_on_create => 1,
};

column updated => {
	data_type => 'timestamp with time zone',
	set_on_create => 1,
	set_on_update => 1,
};

belongs_to 'token_domain', 'DDGC::DB::Result::Token::Domain', 'token_domain_id', {
	on_delete => 'cascade',
};

belongs_to 'language', 'DDGC::DB::Result::Language', 'language_id', {
	on_delete => 'cascade',
};

has_many 'token_languages', 'DDGC::DB::Result::Token::Language', 'token_domain_language_id', {
	cascade_delete => 1,
};

sub event_related {
	my ( $self ) = @_;
	my @related;
	push @related, ['DDGC::DB::Result::Token::Domain',$self->token_domain_id];
	push @related, ['DDGC::DB::Result::Language',$self->language_id];
	return @related;
}

sub insert {
	my $self = shift;
	my $guard = $self->result_source->schema->txn_scope_guard;
	$self->next::method(@_);
	for ($self->token_domain->tokens->all) {
		$self->create_related('token_languages',{
			token_id => $_->id,
		});
	}
	$guard->commit;
	return $self;
}

sub generate_po_for_locale_in_dir_as_with_fallback {
	my ( $self, $basedir, $generator, $fallback ) = @_;
	my $locale = $self->language->locale;
	my $key = $self->token_domain->key;
	my $dt = DateTime->now(
		locale => 'en_US',
		time_zone => 'Pacific/Easter',
	);
	my $datestring = DateTime::Format::Strptime->new(
		pattern => '%F %R%z',
	)->format_datetime($dt);
	my $lang = $self->language->name_in_english;
	my $lang_loc = $self->language->name_in_local;
	my $plural_forms = $self->language->plural_forms;
	my $po_filename = $basedir->file($key.'.po')->absolute;
	my $mo_filename = $basedir->file($key.'.mo')->absolute;
	my $js_filename = $basedir->file($key.'.js')->absolute;
	my $po = io($po_filename);
	my $intro = << "EOF";
#
# Autogenerated by $generator
#
# language: $lang
# locale: $locale
# date: $datestring
#
msgid ""
msgstr ""
"Project-Id-Version: DuckDuckGo-Translation-0.000\\n"
"Last-Translator: Community\\n"
"Language-Team: DuckDuckGo Community <community\@duckduckgo.com>\\n"
"POT-Creation-Date: $datestring\\n"
"PO-Revision-Date: $datestring\\n"
"Language: $lang_loc ($lang)\\n"
"MIME-Version: 1.0\\n"
"Content-Type: text/plain; charset=UTF-8\\n"
"Content-Transfer-Encoding: 8bit\\n"
"Plural-Forms: $plural_forms\\n"

EOF
	$intro > $po;
	my %doublecheck;
	for my $tl ($self->search_related('token_languages',{},{
		prefetch => ['token',{ 
			token_domain_language => [qw( language token_domain )],
			token_language_translations => [{ user => { user_languages => 'language' }, token_language_translation_votes => 'user' }],
		}],
		order_by => [ 'token_language_translations.updated', 'token_language_translations.id' ],
	})->all) {
		$tl->auto_use; # should be renamed
		my $msgid = $tl->token->msgid;
		$msgid .= '||||msgctxt||||'.$tl->token->msgctxt if $tl->token->msgctxt;
		my $tid = $tl->token->id;
		if (defined $doublecheck{$msgid}) {
			warn 'Token #'.$tid.' is a double of Token #'.$doublecheck{$msgid}.', I will ignore it';
		} else {
			$doublecheck{$msgid} = $tid;
			$tl->gettext_snippet($fallback) >> $po;
		}
	}
	die "msgfmt failed" if system("msgfmt -c ".$po_filename." -o ".$mo_filename);
	io($js_filename)->print("\nlocale_data['".$key."'] = ");
	die "po2json failed" if system("po2json ".$po_filename." >> ".$js_filename);
	io($js_filename)->append(";\n");
}

sub is_speakable_by {
    my ($self, $user) = @_;
    return $user->can_speak($self->language->locale);
}

has done_percentage => (
	is => 'ro',
	isa => 'Int',
	lazy_build => 1,
	clearer => 'clear_done_percentage',
);

sub _build_done_percentage {
	my ( $self ) = @_;
	my $untranslated_count;
	my $max_token_count;
	if ($self->has_column_loaded('token_languages_undone_count') && $self->has_column_loaded('token_total_count')) {
		$untranslated_count = $self->get_column('token_languages_undone_count');
		$max_token_count = $self->get_column('token_total_count');
	} else {
		$untranslated_count = $self->untranslated_tokens->count;
		$max_token_count = $self->token_domain->tokens->count;
	}
	return 0 unless $max_token_count;
	return floor(100 * ( ( $max_token_count - $untranslated_count ) / $max_token_count ));
}

sub token_language_comments {
	my ( $self, $page, $pagesize ) = @_;
	$self->result_source->schema->resultset('Comment')->search({
		context => 'DDGC::DB::Result::Token::Language',
		context_id => { -in => $self->token_languages->get_column('id')->as_query },
	},{
		order_by => { -desc => 'me.updated' },
		( ( defined $page and defined $pagesize ) ? (
			page => $page,
			rows => $pagesize,
		) : () ),
		prefetch => 'user',
	});
}

sub _get_token_languages {
	my ( $self, $type, $page, $pagesize, $vars, $extra ) = @_;
	$vars = {} unless defined $vars;
	$extra = {} unless defined $extra;	
	$self->token_languages->search({
		'token.type' => $type,
		%{$vars},
	},{
		order_by => 'me.created',
		( ( defined $page and defined $pagesize ) ? (
			page => $page,
			rows => $pagesize,
		) : () ),
		prefetch => 'token',
		%{$extra},
	});
}

sub search_tokens {
	my ( $self, $page, $pagesize, $search ) = @_;
	$self->_get_token_languages(1, $page, $pagesize, {
		'token.msgid' => { -ilike => '%'.$search.'%'},
		'token.msgid_plural' => { -ilike => '%'.$search.'%'},
		'token.msgctxt' => { -ilike => '%'.$search.'%'},
		'token.notes' => { -ilike => '%'.$search.'%'},
	},{
		join => 'token_language_translations',
	});
}

sub untranslated_tokens {
	my ( $self, $page, $pagesize ) = @_;
	$self->_get_token_languages(1, $page, $pagesize,
	{ 'token_language.id' => {
			-not_in => $self->result_source->schema->resultset('Token::Language::Translation')->search({
				check_result => '1',
			})->get_column('token_language_id')->as_query,
		},
	},
	{
		join => 'token_language_translations',
	});
}

sub msgctxt_tokens {
	my ( $self, $page, $pagesize, $msgctxt ) = @_;
	$self->_get_token_languages(1, $page, $pagesize, {
		'token.msgctxt' => $msgctxt,
	},{
		join => 'token_language_translations',
	});
}

sub all_tokens {
	my ( $self, $page, $pagesize ) = @_;
	$self->_get_token_languages(1, $page, $pagesize);
}

no Moose;
__PACKAGE__->meta->make_immutable;
