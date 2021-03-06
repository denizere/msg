#!/usr/bin/perl -w
use strict;
use lib qw(./msg .);
use Utils;

print "\nMSG\n";
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
printf "%4d-%02d-%02d %02d:%02d:%02d\n\n", $year+1900,$mon+1,$mday,$hour,$min,$sec;

### Make sure all required dependencies are installed
&Utils::test_dependencies();

### Default parameters
### All of these parameters are required
my %default_params = (
        barcodes       => 'NULL',
        re_cutter      => 'MseI',
        linker_system  => 'Dros_SR_vII',
        reads          => 'NULL',
        parent1        => 'NULL',
        parent2        => 'NULL',
        chroms         => 'all',
        sexchroms      => 'X',
        chroms2plot    => 'all',
        deltapar1      => '.01',
        deltapar2      => '.01',
        recRate        => '0',
        rfac		      => '0.00001',
        thinfac	      => '1',
        difffac	      => '.01',
        priors         => '0,.5,.5',
        bwaindex1      => 'bwtsw',
        bwaindex2      => 'bwtsw',
        pnathresh      => '0.03',
        cluster        => '1',
        threads        => '8',
        theta        => '1',
        addl_qsub_option_for_exclusive_node => '',
        addl_qsub_option_for_pe => '',
        custom_qsub_options_for_all_cmds => '',
        bwa_alg => 'aln',
        bwa_threads => '1',
        use_stampy => '0',
        stampy_premap_w_bwa => '1',
        stampy_pseudo_threads => '0',
        quality_trim_reads_thresh => '0',
        quality_trim_reads_consec => '30',
        indiv_stampy_substitution_rate => '0.001',
        indiv_mapq_filter => '0',
        index_file => '',
        index_barcodes => '',
        email_host => '',
        notify_emails => '',
        debug => '0',
        gff_thresh_conf => '.95',
        new_parser => '0',
        new_parser_offset => '0',
        new_parser_filter_out_seq => '',
        pepthresh => '',
        one_site_per_contig => '1',
        full_summary_plots => '1',
        max_mapped_reads => '',
    );

my $params = Utils::parse_config('msg.cfg', \%default_params);
Utils::validate_config($params, qw( barcodes reads parent1 parent2 ));
my %params = %$params;

### check if all the desired chroms are found in both parental files
### report their lengths also
my %par1_reads = &Utils::readFasta($params{'parent1'}, 1);
my %par2_reads = &Utils::readFasta($params{'parent2'}, 1);
my @chroms ;
#when people ask to analyze only part of the genome, then the size of the genome
#changes in the analysis! So, rather than trying to explain all this to end users,
#we decided to see if we can simply trick msg into always using the full genome size.
@chroms = keys %par1_reads ; #<- This is that trick

my $numcontigs = length(@chroms) ;

open (OUT,'>msg.chrLengths') || die "ERROR (msgCluster): Can't create msg.chrLengths: $!\n";
print OUT "chr,length\n";
foreach my $chr (sort @chroms) { print OUT "$chr,$par1_reads{$chr}\n"; } 
close OUT;

####################################################################################################
### Parsing
open (OUT,'>msgRun1.sh');
print OUT "/bin/hostname\n/bin/date\n" .
    'perl msg/msg.pl ' .
    ' --barcodes ' . $params{'barcodes'} .
    ' --re_cutter ' . $params{'re_cutter'} .
    ' --linker_system ' . $params{'linker_system'} .
    ' --reads ' . $params{'reads'} . 
    ' --bwaindex1 ' . $params{'bwaindex1'} .
    ' --bwaindex2 ' . $params{'bwaindex2'} .
    ' --bwa_alg ' . $params{'bwa_alg'} .
    ' --bwa_threads ' . $params{'bwa_threads'} .
    ' --use_stampy ' . $params{'use_stampy'} .
    ' --stampy_premap_w_bwa ' . $params{'stampy_premap_w_bwa'} .
    ' --parent1 ' . $params{'parent1'} .
    ' --parent2 ' . $params{'parent2'} .
    ' --indiv_stampy_substitution_rate ' . $params{'indiv_stampy_substitution_rate'} .
    ' --indiv_mapq_filter ' . $params{'indiv_mapq_filter'} .
    ' --quality_trim_reads_thresh ' . $params{'quality_trim_reads_thresh'} .
    ' --quality_trim_reads_consec ' . $params{'quality_trim_reads_consec'} .
    ' --new_parser ' . $params{'new_parser'} .
    ' --new_parser_offset ' . $params{'new_parser_offset'} .
    " --parse_or_map parse-only";

if ($params{'new_parser_filter_out_seq'}) {
    print OUT ' --new_parser_filter_out_seq ' . $params{'new_parser_filter_out_seq'};
}
if ($params{'index_file'} && $params{'index_barcodes'}) {
    print OUT ' --index_file ' . $params{'index_file'} . ' --index_barcodes ' . $params{'index_barcodes'};
}
print OUT " || exit 100\n";
    
close OUT;
&Utils::system_call("chmod 755 msgRun1.sh");

### Replace barcodes file if using Illumina indexing since we will now have num indexes * num barcodes 
### barcoded individuals from parsing step
if ($params{'index_file'} && $params{'index_barcodes'}) {
    &Utils::system_call(
        "python msg/barcode_splitter.py --make_indexed_msg_barcodes_file --msg_barcodes " . $params{'barcodes'} .
        " --bcfile " . $params{'index_barcodes'});
    $params{'barcodes'} = $params{'barcodes'} . '.after.index.parsing';
}

### Mapping & Plotting
### qsub array: one for each line in the barcode file
my $num_barcodes = 0;
open(FILE,$params{'barcodes'}) || die "ERROR (msgCluster): Can't open $params{'barcodes'}: $!\n";
while (<FILE>) { chomp $_;
	     if ($_ =~ /^\S+\t.*$/) {
            $num_barcodes ++;
	     }
} close FILE;

print "num barcodes is $num_barcodes!\n";

# Note we include some parsing parameters here since the new style parser operates
# at the begining of msgRun2.
open (OUT,'>msgRun2.sh');

if ($params{'cluster'} != 0) {
   print OUT "#!/bin/bash\n/bin/hostname\n/bin/date\n" .
        "start=\$SGE_TASK_ID\n\n" .
        "let end=\"\$start + \$SGE_TASK_STEPSIZE - 1\"\n\n" .
        "for ((h=\$start; h<=\$end; h++)); do\n" .
        #       "   sed -n '1,2p' $params{'barcodes'} > $params{'barcodes'}.\$h\n" .
        #       "   sed -n \"\${h}p\" $params{'barcodes'} >> $params{'barcodes'}.\$h\n" .
        "   sed -n \"\${h}p\" $params{'barcodes'} > $params{'barcodes'}.\$h\n" .
        '   perl msg/msg.pl ' .
        ' --barcodes ' . $params{'barcodes'} . '.$h' .
        ' --reads ' . $params{'reads'} . 
        ' --parent1 ' . $params{'parent1'} . 
        ' --parent2 ' . $params{'parent2'} .
        ' --chroms ' . $params{'chroms'} .
        ' --sexchroms ' . $params{'sexchroms'} .
        ' --chroms2plot ' . $params{'chroms2plot'} .
        ' --parse_or_map map-only' .
        ' --deltapar1 ' . $params{'deltapar1'} .
        ' --deltapar2 ' . $params{'deltapar2'} .
        ' --recRate ' . $params{'recRate'} .
        ' --rfac ' . $params{'rfac'} .
        ' --priors ' . $params{'priors'} .
        ' --theta ' . $params{'theta'} .
        ' --bwa_alg ' . $params{'bwa_alg'} .
        ' --bwa_threads ' . $params{'bwa_threads'} .
        ' --use_stampy ' . $params{'use_stampy'} .
        ' --stampy_premap_w_bwa ' . $params{'stampy_premap_w_bwa'} .
        ' --indiv_stampy_substitution_rate ' . $params{'indiv_stampy_substitution_rate'} .
        ' --indiv_mapq_filter ' . $params{'indiv_mapq_filter'} .
        ' --gff_thresh_conf ' . $params{'gff_thresh_conf'} .
        ' --new_parser ' . $params{'new_parser'} .
        ' --new_parser_offset ' . $params{'new_parser_offset'} .
        ' --re_cutter ' . $params{'re_cutter'} .
        ' --linker_system ' . $params{'linker_system'} .
        ' --quality_trim_reads_thresh ' . $params{'quality_trim_reads_thresh'} .
        ' --quality_trim_reads_consec ' . $params{'quality_trim_reads_consec'} .
        ' --one_site_per_contig ' . $params{'one_site_per_contig'} .
        ' --new_parser_filter_out_seq ' . ($params{'new_parser_filter_out_seq'} || 'null') .
        ' --pepthresh ' . ($params{'pepthresh'} || 'null') .
        ' --max_mapped_reads ' . ($params{'max_mapped_reads'} || 'null') .
        " || exit 100\ndone\n" .
        "/bin/date\n";
} else {
   print OUT "#!/bin/bash\n/bin/hostname\n/bin/date\n" .
        '   perl msg/msg.pl ' .
        ' --barcodes ' . $params{'barcodes'} .
        ' --reads ' . $params{'reads'} . 
        ' --parent1 ' . $params{'parent1'} . 
        ' --parent2 ' . $params{'parent2'} .
        ' --chroms ' . $params{'chroms'} .
        ' --sexchroms ' . $params{'sexchroms'} .
        ' --chroms2plot ' . $params{'chroms2plot'} .
        ' --parse_or_map map-only' .
        ' --deltapar1 ' . $params{'deltapar1'} .
        ' --deltapar2 ' . $params{'deltapar2'} .
        ' --recRate ' . $params{'recRate'} .
        ' --rfac ' . $params{'rfac'} .
        ' --priors ' . $params{'priors'} .
        ' --theta ' . $params{'theta'} .
        ' --bwa_alg ' . $params{'bwa_alg'} .
        ' --bwa_threads ' . $params{'bwa_threads'} .
        ' --use_stampy ' . $params{'use_stampy'} .
        ' --stampy_premap_w_bwa ' . $params{'stampy_premap_w_bwa'} .
        ' --indiv_stampy_substitution_rate ' . $params{'indiv_stampy_substitution_rate'} .
        ' --indiv_mapq_filter ' . $params{'indiv_mapq_filter'} .
        ' --gff_thresh_conf ' . $params{'gff_thresh_conf'} .
        ' --new_parser ' . $params{'new_parser'} .
        ' --new_parser_offset ' . $params{'new_parser_offset'} .
        ' --re_cutter ' . $params{'re_cutter'} .
        ' --linker_system ' . $params{'linker_system'} .
        ' --quality_trim_reads_thresh ' . $params{'quality_trim_reads_thresh'} .
        ' --quality_trim_reads_consec ' . $params{'quality_trim_reads_consec'} .
        ' --one_site_per_contig ' . $params{'one_site_per_contig'} .
        ' --new_parser_filter_out_seq ' . ($params{'new_parser_filter_out_seq'} || 'null') .
        ' --pepthresh ' . ($params{'pepthresh'} || 'null') .
        ' --max_mapped_reads ' . ($params{'max_mapped_reads'} || 'null') .
       "\n";
    }
close OUT;
&Utils::system_call("chmod 755 msgRun2.sh");


####################################################################################################
mkdir "msgOut.$$" unless (-d "msgOut.$$");
mkdir "msgError.$$" unless (-d "msgError.$$");

### Run jobs!

if ($params{'cluster'} != 0) {
    &Utils::system_call("qsub -N msgRun1.$$ -cwd $params{'addl_qsub_option_for_exclusive_node'}$params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n ./msgRun1.sh") ; 
}
else {
    &Utils::system_call("./msgRun1.sh > msgRun1.$$.out 2> msgRun1.$$.err") ; 
}

if ($params{'cluster'} != 0) {
   &Utils::system_call("qsub -N msgRun2.$$ -hold_jid msgRun1.$$ -cwd $params{'addl_qsub_option_for_exclusive_node'}$params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n -t 1-${num_barcodes}:1 ./msgRun2.sh");
   #&Utils::system_call("qsub -N msgRun2.$$ -hold_jid msgRun1.$$ -cwd -b y -V -sync n -t 3-${num_barcodes}:1 ./msgRun2.sh");
   &Utils::system_call("qsub -N msgRun2a.$$ -hold_jid msgRun2.$$ -cwd $params{'addl_qsub_option_for_exclusive_node'}$params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n python msg/create_stats.py -i $params{'reads'} -b $params{'barcodes'}");
   if ($params{'pepthresh'} ne '') {
       &Utils::system_call("qsub -N msgRun2b.$$ -hold_jid msgRun2.$$ -cwd $params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n python msg/hmmprob_to_est.py -d hmm_fit -t $params{'pepthresh'} -o hmm_fits_ests.csv");
   }
   if ($params{'full_summary_plots'} == 1) {
      &Utils::system_call("qsub -N msgRun3.$$ -hold_jid msgRun2.$$ -cwd $params{'addl_qsub_option_for_exclusive_node'}$params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n Rscript msg/summaryPlots.R -c $params{'chroms'} -p $params{'chroms2plot'} -d hmm_fit -t $params{'thinfac'} -f $params{'difffac'} -b $params{'barcodes'} -n $params{'pnathresh'}");
   }
   else {
      &Utils::system_call("qsub -N msgRun3.$$ -hold_jid msgRun2.$$ -cwd $params{'addl_qsub_option_for_exclusive_node'}$params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n python msg/combine.py -d hmm_fit");
   }
   &Utils::system_call("qsub -N msgRun4.$$ -hold_jid msgRun3.$$ -cwd $params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n perl msg/summary_mismatch.pl $params{'barcodes'} 0");
   #Run a simple validation
   &Utils::system_call("qsub -N msgRun5.$$ -hold_jid msgRun4.$$ -cwd $params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n python msg/validate.py $params{'barcodes'} $params{'full_summary_plots'}");
   #Cleanup - move output files to folders, remove barcode related files
   &Utils::system_call("qsub -N msgRun6.$$ -hold_jid msgRun5.$$ -cwd $params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n \"mv -f msgRun*.${$}.e** msgError.$$; mv -f msgRun*.${$}.pe** msgError.$$; mv -f msgRun*.${$}.o* msgOut.$$; mv -f msgRun*.${$}.po* msgOut.$$; mv -f *.trim.log msgOut.$$; truncate -s0 temp.fq; rm -f $params{'barcodes'}.*\"");
   #Notify users that MSG run has completed
   if ($params{'email_host'} && $params{'notify_emails'}) {
        &Utils::system_call("qsub -N msgRun7.$$ -hold_jid msgRun6.$$ -cwd $params{'custom_qsub_options_for_all_cmds'}-b y -V -sync n python msg/send_email.py -e $params{'email_host'}" .
            " -t $params{'notify_emails'} -s \\\"MSG Run has completed\\\"" .
            " -b \\\"NOTE: Output and error messages are located in: msgOut.$$ and msgError.$$\\\""
            );
    }
} else { 
   &Utils::system_call("./msgRun2.sh > msgRun2.$$.out 2> msgRun2.$$.err");
   &Utils::system_call("python msg/create_stats.py -i $params{'reads'} -b $params{'barcodes'}");
   if ($params{'pepthresh'} ne '') {
       &Utils::system_call("python msg/hmmprob_to_est.py -d hmm_fit -t $params{'pepthresh'} -o hmm_fits_ests.csv");
   }
   if ($params{'full_summary_plots'} == 1) {
        &Utils::system_call("Rscript msg/summaryPlots.R -c $params{'chroms'} -p $params{'chroms2plot'} -d hmm_fit -t $params{'thinfac'} -f $params{'difffac'} -b $params{'barcodes'} -n $params{'pnathresh'} > msgRun3.$$.out 2> msgRun3.$$.err");
   }
   else {
        &Utils::system_call("python msg/combine.py -d hmm_fit");
   }
   &Utils::system_call("perl msg/summary_mismatch.pl $params{'barcodes'} 0");
   #Run a simple validation
   &Utils::system_call("python msg/validate.py $params{'barcodes'} $params{'full_summary_plots'} > msgRun.validate.$$.out 2> msgRun.validate.$$.err");
   #Cleanup - move output files to folders, remove barcode related files
   &Utils::system_call("mv -f msgRun*.${$}.e** msgError.$$; mv -f msgRun*.${$}.pe** msgError.$$; mv -f msgRun*.${$}.o* msgOut.$$; mv -f msgRun*.${$}.po* msgOut.$$; mv -f *.trim.log msgOut.$$; rm -f temp.fq; rm -f $params{'barcodes'}.*");
   #Notify users that MSG run has completed
   if ($params{'email_host'} && $params{'notify_emails'}) {
     &Utils::system_call("python msg/send_email.py -e $params{'email_host'}" .
        " -t $params{'notify_emails'} -s 'MSG Run has completed'" .
        " -b 'NOTE: Output and error messages are located in: msgOut.$$ and msgError.$$'"
        );
   }
}

print "\nNOTE: Output and error messages are located in: msgOut.$$ and msgError.$$ \n\n";
exit;
