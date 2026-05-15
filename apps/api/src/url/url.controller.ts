import { Body, Controller, Get, NotFoundException, Param, Post, Res } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Response } from 'express';
import { ShortenResponse } from '@url-shortener/types';
import { ShortenDto } from './shorten.dto';
import { UrlService } from './url.service';
import { REDIRECT_PREFIX } from './url.constants';

@Controller()
export class UrlController {
  private readonly baseUrl: string;

  constructor(
    private readonly urlService: UrlService,
    config: ConfigService,
  ) {
    this.baseUrl = config.get<string>('BASE_URL', 'http://localhost:3001');
  }

  @Post(`${REDIRECT_PREFIX}/data/shorten`)
  async shorten(@Body() dto: ShortenDto): Promise<ShortenResponse> {
    const shortCode = await this.urlService.shortenUrl(dto.longUrl);
    return { shortUrl: `${this.baseUrl}/${REDIRECT_PREFIX}/${shortCode}` };
  }

  @Get(`${REDIRECT_PREFIX}/:shortUrl`)
  async redirect(@Param('shortUrl') shortUrl: string, @Res() res: Response): Promise<void> {
    const longUrl = await this.urlService.getLongUrl(shortUrl);
    if (!longUrl) throw new NotFoundException('Short URL not found');
    res.redirect(302, longUrl);
  }
}
