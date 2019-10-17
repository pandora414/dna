#!/usr/bin/env nextflow



params.output='output'
params.tmp='/tmp'
params.reads1="reads_R1.fastq.gz"
params.reads2="reads_R2.fastq.gz"
params.sample="123456789"


log.info "DNA - NF ~ version 1.0"
log.info "=============================="
log.info "fastq reads1          :  ${params.reads1}"
log.info "fastq reads2          :  ${params.reads2}"
log.info "sample name           :  ${params.sample}"          
log.info "bwa_db_prefix         :  ${params.bwa_db_prefix}"
log.info "ref_sequence          :  ${params.ref_sequence}"
log.info "depth_target          :  ${params.depth_target}"
log.info "gatk_default_target   :  ${params.gatk_default_target}"
log.info "gatk_snp_target       :  ${params.gatk_snp_target}"
log.info "gatk_indel_target     :  ${params.gatk_indel_target}"
log.info "v1000G_phase1_indels_hg19_vcf   :  ${params.v1000G_phase1_indels_hg19_vcf}"
log.info "Mills_and_1000G_gold_standard_indels_hg19_vcf   :  ${params.Mills_and_1000G_gold_standard_indels_hg19_vcf}"
log.info "dbsnp_137_hg19_vcf    :  ${params.dbsnp_137_hg19_vcf}"

log.info "\n"

reads1_file=file(params.reads1)
reads2_file=file(params.reads2)

if( !reads1_file.exists() ) {
  exit 1, "The specified input file does not exist: ${params.reads1}"
}

if( !reads2_file.exists() ) {
  exit 1, "The specified input file does not exist: ${params.reads2}"
}



sample=Channel.from(params.sample)
reads1=Channel.fromPath(params.reads1)
reads2=Channel.fromPath(params.reads2)

process soapnuke{
    tag { sample_name }
    input:
        val sample_name from sample
        file 'sample_R1.fq.gz' from reads1
        file 'sample_R2.fq.gz' from reads2

    output:
        set sample_name,file("*.fastq.gz") into clean_samples

    script:
    """
    SOAPnuke filter -1 sample_R1.fq.gz -2 sample_R2.fq.gz -l 15 -q 0.5 -Q 2 -o . \
        -C sample.clean1.fastq.gz -D sample.clean2.fastq.gz
    """
}

process bwa{
    input:
        set sample_name,files from clean_samples
    
    output:
        set sample_name,file('sample.clean.sam') into sam_res

    script:
    """
    bwa mem -t 2 -M -T 30 ${params.bwa_db_prefix} \
        -R "@RG\tID:${sample_name}\tSM:${sample_name}\tPL:ILLUMINA\tLB:DG\tPU:illumina" \
        ${files[0]} ${files[1]} > sample.clean.sam
    """     
}

process sort{
    //picard=1.1150
    input:
        set sample_name,file('sample.clean.sam') from sam_res
    
    output:
        set sample_name,file('sample.clean.bam') into bam_res

    script:
    """
    java -Xmx2g -Djava.io.tmpdir=${params.tmp} -jar ${params.picard_jar_path}  SortSam \
        INPUT=sample.clean.sam \
        OUTPUT=sample.clean.bam \
        MAX_RECORDS_IN_RAM=500000 \
        SORT_ORDER=coordinate \
        VALIDATION_STRINGENCY=LENIENT \
        CREATE_INDEX=true
    """
}

bam_res.into{bam_res0;bam_res1;bam_res2;bam_res3}

process align_stat{
    //picard=1.1150
    input:
        set sample_name,file('sample.clean.bam') from bam_res0

    script:
        """
        java -Xmx2g -Djava.io.tmpdir=${params.tmp} -jar ${params.picard_jar_path} CollectAlignmentSummaryMetrics \
            INPUT=sample.clean.bam \
            OUTPUT=sample.mapped.stat \
            CREATE_INDEX=true \
            VALIDATION_STRINGENCY=LENIENT \
            REFERENCE_SEQUENCE=${params.ref_sequence}
        """
}

process depth{
    label 'gatk'
    //gatk=3.6
    input:
        set sample_name,file('sample.clean.bam') from bam_res1
    output:
        file('sample.target.basedepth.sample_interval_summary') into depth_res

    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T DepthOfCoverage \
            -R ${params.ref_sequence} \
            -L ${params.depth_target} \
            -I sample.clean.bam \
            -ct 1 -ct 10 -ct 20 -ct 30 -ct 50 -ct 100 -ct 200 -ct 1000 \
            -o sample.target.basedepth
        """
}

process relign{
    label 'gatk'
    //gatk=3.6
    input:
        set sample_name,file('sample.clean.bam') from bam_res2
    output:
        file('sample.realigner.dedupped.clean.intervals') into target_intervals
    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T RealignerTargetCreator \
            -R ${params.ref_sequence} \
            -L ${params.gatk_default_target} \
            -o sample.realigner.dedupped.clean.intervals \
            -I sample.clean.bam \
            -known ${params.v1000G_phase1_indels_hg19_vcf} \
            -known ${params.Mills_and_1000G_gold_standard_indels_hg19_vcf}
        """
}

process IndelRealigner{
    label 'gatk'
    //gatk=3.6
    input:
        set sample_name,file('sample.clean.bam') from bam_res3
        file('sample.realigner.dedupped.clean.intervals') from target_intervals
    
    output:
        set sample_name,file('sample.realigned.clean.bam') into realigned_bam_res
    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T IndelRealigner \
            -filterNoBases \
            -R ${params.ref_sequence} \
            -L ${params.gatk_default_target} \
            -I sample.clean.bam \
            -targetIntervals sample.realigner.dedupped.clean.intervals \
            -o sample.realigned.clean.bam \
            -known ${params.v1000G_phase1_indels_hg19_vcf} \
            -known ${params.Mills_and_1000G_gold_standard_indels_hg19_vcf}
        """
}


realigned_bam_res.into{realigned_bam_res0;realigned_bam_res1}

process BQSR{
    label 'gatk'
    //gatk=3.6
    input:
        set sample_name,file('sample.realigned.clean.bam') from realigned_bam_res0
    
    output:
        file('sample.recal.table') into bsqr_res

    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T BaseRecalibrator \
            -R ${params.ref_sequence} \
            -L ${params.gatk_default_target} \
            -I sample.realigned.clean.bam \
            -knownSites ${params.dbsnp_137_hg19_vcf} \
            -knownSites ${params.Mills_and_1000G_gold_standard_indels_hg19_vcf} \
            -knownSites ${params.v1000G_phase1_indels_hg19_vcf} \
            -o sample.recal.table
        """
}

process print_reads{
    label 'gatk'
    //gatk=3.6
    input:
        set sample_name,file('sample.realigned.clean.bam') from realigned_bam_res1
        file('sample.recal.table') from bsqr_res
    output:
        set sample_name,file('sample.recal.final.clean.bam') into recal_bam_res
    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T PrintReads \
            -R ${params.ref_sequence} \
            -L ${params.gatk_default_target} \
            -I sample.realigned.clean.bam \
            -BQSR sample.recal.table \
            -o sample.recal.final.clean.bam
        """
}

recal_bam_res.into{recal_bam_res0;recal_bam_res1}

process UnifiedGenotyper_snp{
    label 'gatk'
    //gatk=3.6
    publishDir { "${params.output}/snp/"}
    input:
        set sample_name,file('sample.recal.final.clean.bam') from recal_bam_res0
    output:
        set sample_name,file('*.snp.vcf') into snp_vcf_res
    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T UnifiedGenotyper \
            -R ${params.ref_sequence} \
            -I sample.recal.final.clean.bam \
            -glm SNP \
            -D ${params.dbsnp_137_hg19_vcf} \
            -o ${sample_name}.snp.vcf \
            -stand_call_conf 30 \
            -baqGOP 30 \
            -L ${params.gatk_snp_target} \
            -nct 2 \
            -dcov  10000 \
            -U ALLOW_SEQ_DICT_INCOMPATIBILITY -A VariantType -A QualByDepth \
            -A HaplotypeScore -A BaseQualityRankSumTest \
            -A MappingQualityRankSumTest -A ReadPosRankSumTest \
            -A FisherStrand -A DepthPerAlleleBySample \
            -A ClippingRankSumTest \
            --output_mode EMIT_ALL_SITES
        """
}

process UnifiedGenotyper_indel{
    label 'gatk'
    //gatk=3.6
    publishDir { "${params.output}/indel/"}
    input:
        set sample_name,file('sample.recal.final.clean.bam') from recal_bam_res1
    output:
        set sample_name,file('*.indel.vcf') into indel_vcf_res
    script:
        """
        java -Xmx15g -jar ${params.gatk_jar_path} \
            -T UnifiedGenotyper \
            -R ${params.ref_sequence} \
            -I sample.recal.final.clean.bam \
            -glm INDEL \
            -D ${params.dbsnp_137_hg19_vcf} \
            -o ${sample_name}.indel.vcf \
            -stand_call_conf 30 \
            -baqGOP 30 \
            -L ${params.gatk_indel_target} \
            -nct 2 \
            -U ALLOW_SEQ_DICT_INCOMPATIBILITY -A VariantType -A QualByDepth \
            -A HaplotypeScore -A BaseQualityRankSumTest \
            -A MappingQualityRankSumTest -A ReadPosRankSumTest \
            -A FisherStrand -A DepthPerAlleleBySample \
            -A ClippingRankSumTest
        """
}

process genotype{
    publishDir {"${params.output}/genotype/"}

    input:
        set sample_name,file('snp.vcf') from snp_vcf_res
        set sample_name_1,file('indel.vcf') from indel_vcf_res
        file('sample.target.basedepth.sample_interval_summary') from depth_res

    output:
        file("${sample_name}.geno") into genotype_res

    script:
        """
        Rscript $baseDir/bin/dgadultgenotype.R --args -o snp.vcf,indel.vcf,sample.target.basedepth.sample_interval_summary,./${sample_name},${params.gatk_snp_target},${params.genotype_bed}
        """
}

workflow.onComplete {
    def msg="""
Pipeline execution summary
---------------------------
ScriptId        :   ${workflow.scriptId}
ScriptName      :   ${workflow.scriptName}
scriptFile      :   ${workflow.scriptFile}
Repository      :   ${workflow.repository?:'-'}
Revision        :   ${workflow.revision?:'-'}
ProjectDir      :   ${workflow.projectDir}
LaunchDir       :   ${workflow.launchDir}
ConfigFiles     :   ${workflow.configFiles}
Container       :   ${workflow.container}
CommandLine     :   ${workflow.commandLine}
Profile         :   ${workflow.profile}
RunName         :   ${workflow.runName}
SessionId       :   ${workflow.sessionId}
Resume          :   ${workflow.resume}
Start           :   ${workflow.start}

Completed at    :   ${workflow.complete}
Duration        :   ${workflow.duration}
Success         :   ${workflow.success}
Exit status     :   ${workflow.exitStatus}
ErrorMessage    :   -
Error report    :   -
"""
    log.info(msg)

    sendMail(
        to: 'panyunlai@126.com',
        subject: 'dna workflow run complete！',
        body:msg,
        attach:"${workflow.launchDir}/report.html"
    )
}