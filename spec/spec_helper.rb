require 'bundler/setup'
require 'tempfile'
require 'tmpdir'

require 'parallel_tests'
require 'parallel_tests/test/runtime_logger'
require 'parallel_tests/rspec/runtime_logger'
require 'parallel_tests/rspec/summary_logger'

OutputLogger = Struct.new(:output) do
  attr_reader :flock, :flush
  def puts(s=nil)
    self.output << s.to_s
  end
end

module SpecHelper
  def mocked_process
    StringIO.new
  end

  def size_of(group)
    group.map { |test| File.stat(test).size }.inject(:+)
  end

  def use_temporary_directory(&block)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &block) }
  end

  def with_files(files)
    Dir.mktmpdir do |root|
      files.each do |file|
        parent = "#{root}/#{File.dirname(file)}"
        `mkdir -p #{parent}` unless File.exist?(parent)
        `touch #{root}/#{file}`
      end
      yield root
    end
  end
end

module SharedExamples
  def test_tests_in_groups(klass, suffix)
    describe ".tests_in_groups" do
      let(:log) { klass.runtime_log }
      let(:test_root) { "temp" }

      around { |test| use_temporary_directory(&test) }

      before do
        FileUtils.mkdir test_root
        @files = [0,1,2,3,4,5,6,7].map { |i| "#{test_root}/x#{i}#{suffix}" }
        @files.each { |file| File.write(file, 'x' * 100) }
        FileUtils.mkdir_p File.dirname(log)
      end

      def setup_runtime_log
        File.open(log,'w') do |f|
          @files[1..-1].each{|file| f.puts "#{file}:#{@files.index(file)}"}
          f.puts "#{@files[0]}:10"
        end
      end

      it "groups when given an array of files" do
        list_of_files = Dir["#{test_root}/**/*#{suffix}"]
        result = list_of_files.dup
        klass.send(:sort_by_filesize, result)
        result.should =~ list_of_files.map{ |file| [file, File.stat(file).size]}
      end

      it "finds all tests" do
        found = klass.tests_in_groups([test_root], 1)
        all = [ Dir["#{test_root}/**/*#{suffix}"] ]
        (found.flatten - all.flatten).should == []
      end

      it "partitions them into groups by equal size" do
        groups = klass.tests_in_groups([test_root], 2)
        groups.map { |g| size_of(g) }.should == [400, 400]
      end

      it 'should partition correctly with a group size of 4' do
        groups = klass.tests_in_groups([test_root], 4)
        groups.map { |g| size_of(g) }.should == [200, 200, 200, 200]
      end

      it 'should partition correctly with an uneven group size' do
        groups = klass.tests_in_groups([test_root], 3)
        groups.map {|g| size_of(g) }.should =~ [300, 300, 200]
      end

      it "partitions by runtime when runtime-data is available" do
        klass.stub!(:puts)
        setup_runtime_log

        groups = klass.tests_in_groups([test_root], 2)
        groups.size.should == 2
        # 10 + 1 + 3 + 5 = 19
        groups[0].should == [@files[0],@files[1],@files[3],@files[5]]
        # 2 + 4 + 6 + 7 = 19
        groups[1].should == [@files[2],@files[4],@files[6],@files[7]]
      end

      it 'partitions from custom runtime-data location' do
        klass.stub!(:puts)
        log.replace('tmp/custom_runtime.log')
        setup_runtime_log

        groups = klass.tests_in_groups([test_root], 2, runtime_log: log)
        groups.size.should == 2
        # 10 + 1 + 3 + 5 = 19
        groups[0].should == [@files[0],@files[1],@files[3],@files[5]]
        # 2 + 4 + 6 + 7 = 19
        groups[1].should == [@files[2],@files[4],@files[6],@files[7]]
      end

      it "alpha-sorts partitions when runtime-data is available" do
        klass.stub!(:puts)
        setup_runtime_log

        groups = klass.tests_in_groups([test_root], 2)
        groups.size.should == 2

        groups[0].should == groups[0].sort
        groups[1].should == groups[1].sort
      end

      it "partitions by round-robin when not sorting" do
        files = ["file1.rb", "file2.rb", "file3.rb", "file4.rb"]
        klass.should_receive(:find_tests).and_return(files)
        groups = klass.tests_in_groups(files, 2, :group_by => :found).sort
        groups[0].should == ["file1.rb", "file3.rb"]
        groups[1].should == ["file2.rb", "file4.rb"]
      end

      it "alpha-sorts partitions when not sorting by runtime" do
        files = %w[q w e r t y u i o p a s d f g h j k l z x c v b n m]
        klass.should_receive(:find_tests).and_return(files)
        groups = klass.tests_in_groups(files, 2, :group_by => :found).sort
        groups[0].should == groups[0].sort
        groups[1].should == groups[1].sort
      end
    end
  end
end

RSpec.configure do |config|
  config.filter_run :focus => true
  config.run_all_when_everything_filtered = true
  config.include SpecHelper
  config.extend SharedExamples

  # sometimes stuff hangs -> do not hang everything
  config.around do |example|
    Timeout::timeout(30, &example)
  end

  config.after do
    ENV.delete "PARALLEL_TEST_PROCESSORS"
    ENV.delete "PARALLEL_TESTS_EXECUTABLE"
    ENV.delete "TEST_ENV_NUMBER"
    ENV.delete "RAILS_ENV"
  end
end
