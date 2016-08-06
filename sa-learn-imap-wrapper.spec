#
# spec file for package sa-learn-imap-wrapper
#

Name:           sa-learn-imap-wrapper
Version:        1.0.1
Release:        4

BuildRoot:      %{_tmppath}/%{name}-%{version}-build
Source:         sa-learn-imap-wrapper-%{version}.tgz
Summary:        Run sa-learn against remote imap server
License:        GPL
Group:          System/Mail
Requires:       perl-Mail-IMAPClient

%description
Run sa-learn against remote imap server.

%prep
%setup

%build

%install
mkdir -p %{buildroot}/opt/sa-learn-imap-wrapper
cp -rv * %{buildroot}/opt/sa-learn-imap-wrapper

%files
%defattr(-,root,root,-)
%dir /opt/sa-learn-imap-wrapper
%dir /opt/sa-learn-imap-wrapper/bin
%attr(755, root, root) /opt/sa-learn-imap-wrapper/bin/sa-learn-imap-wrapper.pl

%changelog



