#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'pathname'
require 'fileutils'
require 'shellwords'
require 'csv'
require 'json'
require 'rbconfig'
require 'etc'
require 'yaml'

WARMUP_ITRS = ENV.fetch('WARMUP_ITRS', 15).to_i

# Check which OS we are running
def os
  @os ||= (
    host_os = RbConfig::CONFIG['host_os']
    case host_os
    when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
      :windows
    when /darwin|mac os/
      :macosx
    when /linux/
      :linux
    when /solaris|bsd/
      :unix
    else
      raise "unknown os: #{host_os.inspect}"
    end
  )
end

# Checked system - error if the command fails
def check_call(command, verbose: false, env: {})
  puts(command)

  if verbose
    status = system(env, command, out: $stdout, err: :out)
  else
    status = system(env, command)
  end

  unless status
    puts "Command #{command.inspect} failed in directory #{Dir.pwd}"
    raise RuntimeError.new
  end
end

def check_output(command)
  IO.popen(command, &:read)
end

def set_bench_config()
  # Only available on intel systems
  if File.exist?('/sys/devices/system/cpu/intel_pstate')
    # sudo requires the flag '-S' in order to take input from stdin
    check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
    check_call("sudo -S sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
  end
end

def check_chruby()
  ruby = RbConfig.ruby
  ruby_version = check_output("#{ruby} -v --yjit").strip

  if !ruby_version.downcase.include?("yjit")
    puts "Your current Ruby (#{ruby}) doesn't seem to include YJIT."
    puts "Maybe you need to chruby to ruby-yjit?"
    puts "  chruby ruby-yjit"
    exit(-1)
  end
end

def check_pstate()
  # Only available on intel systems
  if !File.exist?('/sys/devices/system/cpu/intel_pstate/no_turbo')
    return
  end

  File.open('/sys/devices/system/cpu/intel_pstate/no_turbo', mode='r') do |file|
    if file.read.strip != '1'
      puts("You forgot to disable turbo:")
      puts("  sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
      exit(-1)
    end
  end

  if !File.exist?('/sys/devices/system/cpu/intel_pstate/min_perf_pct')
    return
  end

  File.open('/sys/devices/system/cpu/intel_pstate/min_perf_pct', mode='r') do |file|
    if file.read.strip != '100'
      puts("You forgot to set the min perf percentage to 100:")
      puts("  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
      exit(-1)
    end
  end
end

def table_to_str(table_data, format)
  # Trim numbers to one decimal for console display
  # Keep two decimals for the speedup ratios

  table_data = table_data.first(1) + table_data.drop(1).map { |row|
    format.zip(row).map { |fmt, data| fmt % data }
  }

  num_rows = table_data.length
  num_cols = table_data[0].length

  # Pad each column to the maximum width in the column
  (0...num_cols).each do |c|
    cell_lens = (0...num_rows).map { |r| table_data[r][c].length }
    max_width = cell_lens.max
    (0...num_rows).each { |r| table_data[r][c] = table_data[r][c].ljust(max_width) }
  end

  # Row of separator dashes
  sep_row = (0...num_cols).map { |i| '-' * table_data[0][i].length }.join('  ')

  out = sep_row + "\n"

  table_data.each do |row|
    out += row.join('  ') + "\n"
  end

  out += sep_row

  return out
end

def mean(values)
  return values.sum(0.0) / values.size
end

def stddev(values)
  xbar = mean(values)
  diff_sqrs = values.map { |v| (v-xbar)*(v-xbar) }
  mean_sqr = diff_sqrs.sum(0.0) / values.length
  return Math.sqrt(mean_sqr)
end

def free_file_no(prefix)
  (1..).each do |file_no|
    out_path = File.join(prefix, "output_%03d.csv" % file_no)
    if !File.exist?(out_path)
      return file_no
    end
  end
end

# Check if the name matches any of the names in a list of filters
def match_filter(name, filters)
  if filters.length == 0
    return true
  end

  filters.each do |filter|
    if name.downcase.include?(filter)
      return true
    end
  end

  return false
end

# Resolve the pre_init file path into a form that can be required
def expand_pre_init(path)
  path = Pathname.new(path)

  unless path.exist?
    puts "--with-pre-init called with non-existent file!"
    exit(-1)
  end

  if path.directory?
    puts "--with-pre-init called with a directory, please pass a .rb file"
    exit(-1)
  end

  library_name = path.basename(path.extname)
  load_path = path.parent.expand_path

  [
    "-I", load_path,
    "-r", library_name
  ]
end

def sort_benchmarks(bench_names)
  benchmarks = YAML.load_file('benchmarks.yml')
  headline_benchmarks = benchmarks.select { |_, metadata| metadata['category'] == 'headline' }.keys
  micro_benchmarks = benchmarks.select { |_, metadata| metadata['category'] == 'micro' }.keys

  headline_names, bench_names = bench_names.partition { |name| headline_benchmarks.include?(name) }
  micro_names, other_names = bench_names.partition { |name| micro_benchmarks.include?(name) }
  headline_names.sort + other_names.sort + micro_names.sort
end

# Run all the benchmarks and record execution times
def run_benchmarks(ruby:, ruby_description:, name_filters:, out_path:, pre_init:, rss:)
  bench_times = {}
  bench_rss = {}

  # Get the list of benchmark files/directories matching name filters
  bench_files = Dir.children('benchmarks').sort.filter do |entry|
    match_filter(entry, name_filters)
  end

  if pre_init
    pre_init = expand_pre_init(pre_init)
  end

  bench_files.each_with_index do |entry, idx|
    bench_name = entry.gsub('.rb', '')

    puts("Running benchmark \"#{bench_name}\" (#{idx+1}/#{bench_files.length})")

    # Path to the benchmark runner script
    script_path = File.join('benchmarks', entry)

    if !script_path.end_with?('.rb')
      script_path = File.join(script_path, 'benchmark.rb')
    end

    # Set up the environment for the benchmarking command
    ENV["OUT_CSV_PATH"] = File.join(out_path, 'temp.csv')
    ENV["WARMUP_ITRS"] = WARMUP_ITRS.to_s
    if rss
      ENV["RSS_CSV_PATH"] = File.join(out_path, 'rss.csv')
    end

    # Set up the benchmarking command
    cmd = []
    if os == :linux
      # Disable address space randomization (for determinism)
      cmd += ["setarch", `uname -m`.strip, "-R"]

      # Pin the process to one given core to improve caching and reduce variance on CRuby
      # Other Rubies need to use multiple cores, e.g., for JIT threads
      if ruby_description.start_with?('ruby ')
        cmd += ["taskset", "-c", "#{Etc.nprocessors - 1}"]
      end
    end

    cmd += [
      *ruby,
      "-I", "./harness",
      *pre_init,
      script_path,
    ].compact

    # When the Ruby running this script is not the first Ruby in PATH, shell commands
    # like `bundle install` in a child process will not use the Ruby being benchmarked.
    # It overrides PATH to guarantee the commands of the benchmarked Ruby will be used.
    env = {}
    if `#{ruby.first} -e 'print RbConfig.ruby'` != RbConfig.ruby
      env["PATH"] = "#{File.dirname(ruby.first)}:#{ENV["PATH"]}"

      # chruby sets GEM_HOME and GEM_PATH in your shell. We have to unset it in the child
      # process to avoid installing gems to the version that is running run_benchmarks.rb.
      ["GEM_HOME", "GEM_PATH"].each do |var|
        env[var] = nil if ENV.key?(var)
      end
    end

    # Do the benchmarking
    check_call(cmd.shelljoin, env: env)

    # Read the benchmark data
    # Convert times to ms
    ruby_description, *times = File.readlines(ENV["OUT_CSV_PATH"])
    times = times.map { |v| 1000 * Float(v) }
    bench_times[bench_name] = times

    # Read the RSS data, converting bytes to MiB
    if rss
      bench_rss[bench_name] = File.read(ENV["RSS_CSV_PATH"]).to_i / 1024.0 / 1024.0
    end
  end

  return bench_times, bench_rss
end

# Default values for command-line arguments
args = OpenStruct.new({
  executables: {},
  out_path: "./data",
  yjit_opts: "",
  name_filters: [],
  rss: false,
})

OptionParser.new do |opts|
  opts.on("-e=NAME::RUBY_PATH OPTIONS", "ruby executable and options to be benchmarked (default: interp, yjit)") do |v|
    name, executable = v.split("::", 2)
    if executable.nil?
      executable = name # allow skipping `NAME::`
    end
    args.executables[name] = executable.shellsplit
  end

  opts.on("--chruby=NAME::VERSION OPTIONS", "ruby version under chruby and options to be benchmarked") do |v|
    name, version = v.split("::", 2)
    if version.nil?
      version = name # allow skipping `NAME::`
    end
    version, *options = version.shellsplit
    unless executable = ["/opt/rubies/#{version}/bin/ruby", "#{ENV["HOME"]}/.rubies/#{version}/bin/ruby"].find { |path| File.executable?(path) }
      abort "Cannot find '#{version}' in /opt/rubies or ~/.rubies"
    end
    args.executables[name] = [executable, *options]
  end

  opts.on("--out_path=OUT_PATH", "directory where to store output data files") do |v|
    args.out_path = v
  end

  opts.on("--name_filters=x,y,z", Array, "when given, only benchmarks with names that contain one of these strings will run") do |list|
    args.name_filters = list
  end

  opts.on("--yjit_opts=OPT_STRING", "string of command-line options to run YJIT with (ignored if you use -e)") do |str|
    args.yjit_opts=str
  end

  opts.on("--with_pre-init=PRE_INIT_FILE",
          "a file to require before each benchmark run, so settings can be tuned (eg. enable/disable GC compaction)") do |str|
    args.with_pre_init = str
  end

  opts.on("--rss", "measure RSS after benchmark iterations") do
    args.rss = true
  end
end.parse!

# Remaining arguments are treated as benchmark name filters
if ARGV.length > 0
  args.name_filters += ARGV
end

# If -e is not specified, compare the interpreter and YJIT of the current Ruby
if args.executables.empty?
  args.executables["interp"] = [RbConfig.ruby]
  args.executables["yjit"] = [RbConfig.ruby, "--yjit", *args.yjit_opts.shellsplit]

  # Check that the chruby command was run
  # Note: we intentionally do this first
  check_chruby()
end

# Disable CPU frequency scaling
set_bench_config()

# Check pstate status
check_pstate()

# Create the output directory
FileUtils.mkdir_p(args.out_path)

ruby_descriptions = {}
args.executables.each do |name, executable|
  ruby_descriptions[name] = check_output([*executable, "-v"]).chomp
end

# Benchmark with and without YJIT
bench_start_time = Time.now.to_f
bench_times = {}
bench_rss = {}
args.executables.each do |name, executable|
  bench_times[name], bench_rss[name] = run_benchmarks(
    ruby: executable,
    ruby_description: ruby_descriptions[name],
    name_filters: args.name_filters,
    out_path: args.out_path,
    pre_init: args.with_pre_init,
    rss: args.rss,
  )
end
bench_end_time = Time.now.to_f
bench_names = sort_benchmarks(bench_times.first.last.keys)

bench_total_time = (bench_end_time - bench_start_time).to_i
puts("Total time spent benchmarking: #{bench_total_time}s")
puts()

# Table for the data we've gathered
base_name, *other_names = args.executables.keys
table  = [["bench", "#{base_name} (ms)", "stddev (%)"]]
format =  ["%s",    "%.1f",              "%.1f"]
if args.rss
  table[0] += ["RSS (MiB)"]
  format   += ["%.1f"]
end
other_names.each do |name|
  table[0] += ["#{name} (ms)", "stddev (%)"]
  format   += ["%.1f",         "%.1f"]
  if args.rss
    table[0] += ["RSS (MiB)"]
    format   += ["%.1f"]
  end
end
other_names.each do |name|
  table[0] += ["#{base_name}/#{name}"]
  format   += ["%.2f"]
end
other_names.each do |name|
  table[0] += ["#{name} 1st itr"]
  format   += ["%.2f"]
end

# Format the results table
bench_names.each do |bench_name|
  other_ts = other_names.map { |other_name| bench_times[other_name][bench_name] }
  other_rsss = other_names.map { |other_name| bench_rss[other_name][bench_name] }
  base_t = bench_times[base_name][bench_name]
  base_rss = bench_rss[base_name][bench_name]

  other_t0s = other_ts.map { |other_t| other_t[0] }
  other_ts = other_ts.map { |other_t| other_t[WARMUP_ITRS..] }
  base_t0 = base_t[0]
  base_t = base_t[WARMUP_ITRS..]
  ratio_1sts = other_t0s.map { |other_t0| base_t0 / other_t0 }
  ratios = other_ts.map { |other_t| mean(base_t) / mean(other_t) }

  row = [bench_name, mean(base_t), 100 * stddev(base_t) / mean(base_t), base_rss]
  other_ts.zip(other_rsss).each do |other_t, other_rss|
    row += [mean(other_t), 100 * stddev(other_t) / mean(other_t), other_rss]
  end

  row += ratios + ratio_1sts

  table.append(row.compact)
end

# Find a free file index for the output files
file_no = free_file_no(args.out_path)

# Save the raw data as JSON
out_json_path = File.join(args.out_path, "output_%03d.json" % file_no)
File.open(out_json_path, "w") do |file|
  out_data = {
    'metadata': ruby_descriptions,
  }
  out_data.merge!(bench_times)
  json_str = JSON.generate(out_data)
  file.write json_str
end

# Save data as CSV so we can produce tables/graphs in a spreasheet program
# NOTE: we don't do any number formatting for the output file because
#       we don't want to lose any precision
output_rows = []
ruby_descriptions.each do |key, value|
  output_rows.append([key, value])
end
output_rows.append([])
output_rows.concat(table)
out_tbl_path = File.join(args.out_path, 'output_%03d.csv' % file_no)
CSV.open(out_tbl_path, "wb") do |csv|
  output_rows.each do |row|
    csv << row
  end
end

# Save the output in a text file that we can easily refer to
output_str = ""
ruby_descriptions.each do |key, value|
  output_str << "#{key}: #{value}\n"
end
output_str += "\n"
output_str += table_to_str(table, format) + "\n"
unless other_names.empty?
  output_str << "Legend:\n"
  other_names.each do |name|
    output_str << "- #{base_name}/#{name}: ratio of #{base_name}/#{name} time. Higher is better for #{name}. Above 1 represents a speedup.\n"
    output_str << "- #{name} 1st itr: ratio of #{base_name}/#{name} time for the first benchmarking iteration.\n"
  end
end
out_txt_path = File.join(args.out_path, "output_%03d.txt" % file_no)
File.open(out_txt_path, "w") { |f| f.write output_str }

# Print the table to the console, with numbers truncated
puts(output_str)
