#
# Win32::Console::ANSI
#
# Copyright 2004 - Gonzalo Garramuno
# Licensed under GNU General Public License or Perl's Artistic License
#
# Based on Perl's Win32::Console::ANSI
# Copyright (c) 2003 Jean-Louis Morel <jl_morel@bribes.org>
# Licensed under GNU General Public License or Perl's Artistic License
#
require "Win32/Console"


module Kernel

  # Kernel#putc is equivalent to $stdout.putc, but
  # it doesn't use $stdout.putc.  We redefine it to do that
  # so that it will buffer the escape sequences properly.
  # See Win32::Console::ANSI::IO#putc
  remove_method :putc
  def putc(int)
    $stdout.putc(int)
  end

end

module Win32
  class Console
    module ANSI

      class IO < IO

        VERSION = '0.05'
        DEBUG = nil

        require "win32/registry"

        include Win32::Console::Constants

        # @todo: encode is another perl module
        EncodeOk = false

        # Retrieving the codepages
        cpANSI = nil
        Win32::Registry::HKEY_LOCAL_MACHINE.open('SYSTEM\CurrentControlSet\Control\Nls\CodePage' ) { |reg|
          cpANSI = reg['ACP']
        }

        STDERR.puts "Unable to read Win codepage #{cpANSI}" if DEBUG && !cpANSI


        cpANSI = 'cp'+(cpANSI ? cpANSI : '1252')      # Windows codepage
        OEM = Win32::Console::OutputCP()
        cpOEM = 'cp' + OEM.to_s                       # DOS codepage
        @@cp = cpANSI + cpOEM

        STDERR.puts "EncodeOk=#{EncodeOk} cpANSI=#{cpANSI} "+
          "cpOEM=#{cpOEM}" if DEBUG

        @@color = { 30 => 0,                                               # black foreground
              31 => FOREGROUND_RED,                                  # red foreground
              32 => FOREGROUND_GREEN,                                # green foreground
              33 => FOREGROUND_RED|FOREGROUND_GREEN,                 # yellow foreground
              34 => FOREGROUND_BLUE,                                 # blue foreground
              35 => FOREGROUND_BLUE|FOREGROUND_RED,                  # magenta foreground
              36 => FOREGROUND_BLUE|FOREGROUND_GREEN,                # cyan foreground
              37 => FOREGROUND_RED|FOREGROUND_GREEN|FOREGROUND_BLUE, # white foreground
              40 => 0,                                               # black background
              41 => BACKGROUND_RED,                                  # red background
              42 => BACKGROUND_GREEN,                                # green background
              43 => BACKGROUND_RED|BACKGROUND_GREEN,                 # yellow background
              44 => BACKGROUND_BLUE,                                 # blue background
              45 => BACKGROUND_BLUE|BACKGROUND_RED,                  # magenta background
              46 => BACKGROUND_BLUE|BACKGROUND_GREEN,                # cyan background
              47 => BACKGROUND_RED|BACKGROUND_GREEN|BACKGROUND_BLUE, # white background
        }

        def initialize
          super(1,'w')
          @Out = Win32::Console.new(STD_OUTPUT_HANDLE)
          @x = @y = 0           # to save cursor position
          @foreground = 7
          @background = 0
          @bold =
          @underline =
          @revideo =
          @concealed = nil
          @conv = 1        # char conversion by default
          @buffer = []
          STDERR.puts "Console Mode=#{@Out.Mode}" if DEBUG
        end

        # this redefined #putc buffers escape sequences but passes
        # other values to #write as normal.
        def putc(int)
          if @buffer.empty?
            unless int == ?\e
               write(int.chr)
            else
              @buffer << int
            end
          else
            @buffer << int
            case int
            when ?m, ?J, ?L, ?M, ?@, ?P, ?A, ?B, ?C, ?D,
                 ?E, ?F, ?G, ?H, ?f, ?s, ?u, ?U, ?K, ?X
              write(@buffer.pack("c*"))
              @buffer.clear
            end
          end
        end

        # #write checks if $stdout is going to the console
        # or if it's being redirected.
        # When to the console, it passes the string to
        # _PrintString to be parsed for escape codes.
        #
        # When redirected, it passes to WriteFile to allow escape
        # codes and all to be output.  The application that is
        # handling the redirected IO should handle coloring.
        # For Ruby applications, this means requiring Win32Conole again.
        def write(*s)
          if redirected?
            s.each{ |x| @Out.WriteFile(x.dup.to_s) }
          else
            s.each{ |x| _PrintString(x) }
          end
        end

        # returns true if outputs is being redirected.
        def redirected?
          @Out.Mode > 31
        end

        private

        def _PrintString(t)
          s = t.dup.to_s
          while s != ''
            if s.sub!(/([^\e]*)?\e([\[\(])([0-9\;\=]*)([a-zA-Z@])(.*)/,'\5')
              @Out.Write((_conv("#$1")))
              if $2 == '['
                case $4
                when 'm'        # ESC[#;#;....;#m Set display attributes
                  attributs = $3.split(';')
                  attributs.push(nil) unless attributs  # ESC[m == ESC[;m ==...==ESC[0m
                  attributs.each do |attr|
                    atv = attr.to_i
                    case atv
                    when 0  # ESC[0m reset
                      @foreground = 7
                      @background = 0
                      @bold =
                      @underline =
                      @revideo =
                      @concealed = nil
                    when 1
                      @bold = 1
                    when 21
                      @bold = nil
                    when 4
                      @underline = 1
                    when 24
                      @underline = nil
                    when 7
                      @revideo = 1
                    when 27
                      @revideo = nil
                    when 8
                      @concealed = 1
                    when 28
                      @concealed = nil
                    when 30..37
                      @foreground = atv - 30
                    when 40..47
                      @background = atv - 40
                    end
                  end

                  if @revideo
                    attribut = @@color[40+@foreground] |
                      @@color[30+@background]
                  else
                    attribut = @@color[30+@foreground] |
                      @@color[40+@background]
                  end
                  attribut |= FOREGROUND_INTENSITY if @bold
                  attribut |= BACKGROUND_INTENSITY if @underline
                  @Out.Attr(attribut)
                when 'J'
                  if !$3 or $3 == ''  # ESC[0J from cursor to end of display
                    info = @Out.Info()
                    s = ' ' * ((info[1]-info[3]-1)*info[0]+info[0]-info[2]-1)
                    @Out.WriteChar(s, info[2], info[3])
                    @Out.Cursor(info[2], info[3])
                  elsif $3 == '1' # ESC[1J erase from start to cursor.
                    info = @Out.Info()
                    s = ' ' * (info[3]*info[0]+info[2]+1)
                    @Out.WriteChar(s, 0, 0)
                    @Out.Cursor(info[2], info[3])
                  elsif $3 == '2' # ESC[2J Clear screen and home cursor
                    @Out.Cls()
                    @Out.Cursor(0, 0)
                  else
                    STDERR.print "\e#$2#$3#$4" if DEBUG # if ESC-code not implemented
                  end
                when 'K'
                  info = @Out.Info()
                  if !$3 or $3 == ''                  # ESC[0K Clear to end of line
                    s = ' ' * (info[7]-info[2]+1)
                    @Out.Write(s)
                    @Out.Cursor(info[2], info[3])
                  elsif $3=='1'   # ESC[1K Clear from start of line to cursor
                    s = ' '*(info[2]+1)
                    @Out.WriteChar(s, 0, info[3])
                    @Out.Cursor(info[2], info[3])
                  elsif $3=='2'   # ESC[2K Clear whole line.
                    s = ' '* info[0]
                    @Out.WriteChar(s, 0, info[3])
                    @Out.Cursor(info[2], info[3])
                  end
                when 'L'  # ESC[#L Insert # blank lines.
                  n = $3 == ''? 1 : $3.to_i  # ESC[L == ESC[1L
                  info = @Out.Info()
                  @Out.Scroll(0, info[3], info[0]-1, info[1]-1,
                              0, info[3] + n.to_i,
                               ' '[0], @Out.Attr(),
                               0, 0, 10000, 10000)
                  @Out.Cursor(info[2], info[3])
                when 'M'   # ESC[#M Delete # line.
                  n = $3 == ''? 1 : $3.to_i  # ESC[M == ESC[1M
                  info = @Out.Info();
                  @Out.Scroll(0, info[3]+n, info[0]-1, info[1]-1,
                              0, info[3],
                              ' '[0], @Out.Attr(),
                              0, 0, 10000, 10000)
                  @Out.Cursor(info[2], info[3])
                when 'P'   # ESC[#P Delete # characters.
                  n = $3 == ''? 1 : $3.to_i  # ESC[P == ESC[1P
                  info = @Out.Info()
                  n = info[0]-info[2] if info[2]+n > info[0]-1
                  @Out.Scroll(info[2]+n, info[3] , info[0]-1, info[3],
                              info[2], info[3],
                              ' '[0], @Out.Attr(),
                              0, 0, 10000, 10000)
                  s = ' ' * n
                  @Out.Cursor(info[0]-n, info[3])
                  @Out.Write(s)
                  @Out.Cursor(info[2], info[3])
                when '@'      # ESC[#@ Insert # blank Characters
                  s = ' ' * $3.to_i
                  info = @Out.Info()
                  s << @Out.ReadChar(info[7]-info[2]+1, info[2], info[3])
                  s = s[0..-($3.to_i)]
                  @Out.Write(s);
                  @Out.Cursor(info[2], info[3])
                when 'A'     # ESC[#A Moves cursor up # lines
                  (x, y) = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[A == ESC[1A
                  @Out.Cursor(x, y-n)
                when 'B'    # ESC[#B Moves cursor down # lines
                  (x, y) = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[B == ESC[1B
                  @Out.Cursor(x, y+n)
                when 'C'    # ESC[#C Moves cursor forward # spaces
                  (x, y) = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[C == ESC[1C
                  @Out.Cursor(x+n, y)
                when 'D'    # ESC[#D Moves cursor back # spaces
                  (x, y) = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[D == ESC[1D
                  @Out.Cursor(x-n, y)
                when 'E'    # ESC[#E Moves cursor down # lines, column 1.
                  x, y = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[E == ESC[1E
                  @Out.Cursor(0, y+n)
                when 'F'    # ESC[#F Moves cursor up # lines, column 1.
                  x, y = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[F == ESC[1F
                  @Out.Cursor(0, y-n)
                when 'G'   # ESC[#G Moves cursor column # in current row.
                  x, y = @Out.Cursor()
                  n = $3 == ''? 1 : $3.to_i;  # ESC[G == ESC[1G
                  @Out.Cursor(n-1, y)
                when 'f' # ESC[#;#f Moves cursor to line #, column #
                  y, x = $3.split(';')
                  x = 1 unless x    # ESC[;5H == ESC[1;5H ...etc
                  y = 1 unless y
                  @Out.Cursor(x.to_i-1, y.to_i-1) # origin (0,0) in DOS console
                when 'H' # ESC[#;#H  Moves cursor to line #, column #
                  y, x = $3.split(';')
                  x = 1 unless x    # ESC[;5H == ESC[1;5H ...etc
                  y = 1 unless y
                  @Out.Cursor(x.to_i-1, y.to_i-1) # origin (0,0) in DOS console
                when 's'       # ESC[s Saves cursor position for recall later
                  (@x, @y) = @Out.Cursor()
                when 'u'       # ESC[u Return to saved cursor position
                  @Out.Cursor(@x, @y)
                when 'U'     # ESC(U no mapping
                  @conv = nil
                when 'K'     # ESC(K mapping if it exist
                  @Out.OutputCP(OEM)      # restore original codepage
                  @conv = 1
                when 'X'     # ESC(#X codepage **EXPERIMENTAL**
                  @conv = nil
                  @Out.OutputCP($3)
                else
                  STDERR.puts "\e#$2#$3#$4 not implemented" if DEBUG # ESC-code not implemented
                end
              end
            else
              @Out.Write(_conv(s))
              s=''
            end
          end
        end

        def _conv(s)
          if @concealed
            s.gsub!( /\S/,' ')
          elsif @conv
            if EncodeOk
              from_to(s, cpANSI, cpOEM)
            elsif @@cp == 'cp1252cp850'      # WinLatin1 --> DOSLatin1
              s.tr!("\x80\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8E\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFB\xFC\xFD\xFE\xFF",
                    "  \x9f                        \xff\xad\xbd\x9c\xcf\xbe\xdd\xf5\xf9\xb8\xa6\xae\xaa\xf0\xa9\xee\xf8\xf1\xfd\xfc\xef\xe6\xf4\xfa\xf7\xfb\xa7\xaf\xac\xab\xf3\xa8\xb7\xb5\xb6\xc7\x8e\x8f \x80\xd4\x90\xd2\xd3\xde\xd6\xd7\xd8\xd1\xa5\xe3\xe0\xe2\xe5\x99\x9e\x9d\xeb\xe9\xea\x9a\xed\xe8\xe1\x85\xa0\x83\xc6\x84\x86 \x87\x8a\x82\x88\x89\x8d\xa1\x8c\x8b\xd0\xa4\x95\xa2\x93\xe4\x94\xf6\x9b\x97\xa3\x96\x81\xec\xe7\x98")
            elsif @@cp == 'cp1252cp437'      # WinLatin1 --> DOSLatinUS
              s.tr!("\x80\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8E\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFB\xFC\xFD\xFE\xFF",
                    "  \x9f                        \xff\xad\x9b\x9c \x9d    \xa6\xae\xaa   \xf8\xf1\xfd  \xe6 \xfa  \xa7\xaf\xac\xab \xa8    \x8e\x8f \x80 \x90       \xa5    \x99     \x9a  \xe1\x85\xa0\x83 \x84\x86 \x87\x8a\x82\x88\x89\x8d\xa1\x8c\x8b \xa4\x95\xa2\x93 \x94\xf6 \x97\xa3\x96\x81  \x98")
            elsif @@cp == 'cp1250cp852'      # WinLatin2 --> DOSLatin2
              s.tr!("\x80\x82\x84\x85\x86\x87\x89\x8A\x8B\x8C\x8D\x8E\x8F\x91\x92\x93\x94\x95\x96\x97\x99\x9A\x9B\x9C\x9D\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFC\xFD\xFE\xFF",
                    "       \xe6 \x97\x9b\xa6\x8d        \xe7 \x98\x9c\xa7\xab\xff\xf3\xf4\x9d\xcf\xa4 \xf5\xf9 \xb8\xae\xaa\xf0 \xbd\xf8 \xf2\x88\xef   \xf7\xa5\xad\xaf\x95\xf1\x96\xbe\xe8\xb5\xb6\xc6\x8e\x91\x8f\x80\xac\x90\xa8\xd3\xb7\xd6\xd7\xd2\xd1\xe3\xd5\xe0\xe2\x8a\x99\x9e\xfc\xde\xe9\xeb\x9a\xed\xdd\xe1\xea\xa0\x83\xc7\x84\x92\x86\x87\x9f\x82\xa9\x89\xd8\xa1\x8c\xd4\xd0\xe4\xe5\xa2\x93\x8b\x94\xf6\xfd\x85\xa3\x81\xec\xee\xfa")
            elsif @@cp == 'cp1251cp855'      # WinCyrillic --> DOSCyrillic
              s.tr!("\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F\x90\x91\x92\x93\x94\x95\x96\x97\x99\x9A\x9B\x9C\x9D\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xFA\xFB\xFC\xFD\xFE\xFF",
                    "\x81\x83 \x82      \x91 \x93\x97\x95\x9b\x80        \x90 \x92\x96\x94\x9a\xff\x99\x98\x8f\xcf  \xfd\x85 \x87\xae \xf0 \x8d  \x8b\x8a    \x84\xef\x86\xaf\x8e\x89\x88\x8c\xa1\xa3\xec\xad\xa7\xa9\xea\xf4\xb8\xbe\xc7\xd1\xd3\xd5\xd7\xdd\xe2\xe4\xe6\xe8\xab\xb6\xa5\xfc\xf6\xfa\x9f\xf2\xee\xf8\x9d\xe0\xa0\xa2\xeb\xac\xa6\xa8\xe9\xf3\xb7\xbd\xc6\xd0\xd2\xd4\xd6\xd8\xe1\xe3\xe5\xe7\xaa\xb5\xa4\xfb\xf5\x9e\xf1\xed\xf7\x9c\xde")
            end
          end
          return s
        end

      end

# end print overloading

    end
  end
end

$stdout = Win32::Console::ANSI::IO.new()
